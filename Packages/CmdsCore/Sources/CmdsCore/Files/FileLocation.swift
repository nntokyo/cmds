import Foundation

/// Where a files pane, a source or a transfer destination is (docs/guide/files.md "Folders on SSH hosts"): a path on
/// this Mac, or a path on an SSH host reached through the user's own `ssh` (`HOST` as for `cmds new --ssh`).
public enum FileLocation: Hashable, Sendable, CustomStringConvertible {
    case local(String)
    /// `path` is absolute once the connection has resolved it; as typed it may also be `~`, `~/…` or relative to the
    /// remote home (`""` = home).
    case remote(host: String, path: String)

    public var path: String {
        switch self {
        case .local(let path), .remote(_, let path): return path
        }
    }

    public var host: String? {
        if case .remote(let host, _) = self { return host }
        return nil
    }

    public var isRemote: Bool { host != nil }

    /// `HOST:PATH` for remote locations (as `cmds files` takes them), the path for local ones.
    public var description: String {
        switch self {
        case .local(let path): return path
        case .remote(let host, let path): return "\(host):\(path)"
        }
    }

    /// The same tree (this Mac, or one host), so a move can be a rename.
    public func isSameTree(as other: FileLocation) -> Bool { host == other.host }

    public func appending(_ name: String) -> FileLocation {
        switch self {
        case .local(let path): return .local((path as NSString).appendingPathComponent(name))
        case .remote(let host, let path): return .remote(host: host, path: RemotePath.join(path, name))
        }
    }

    public var name: String {
        switch self {
        case .local(let path): return (path as NSString).lastPathComponent
        case .remote(_, let path): return RemotePath.name(path)
        }
    }

    public var parent: FileLocation {
        switch self {
        case .local(let path): return .local((path as NSString).deletingLastPathComponent)
        case .remote(let host, let path): return .remote(host: host, path: RemotePath.parent(path))
        }
    }

    /// Splits a command-line argument like scp: `HOST:PATH` is remote when the colon comes before any `/` (so a local
    /// name with a colon is written `./a:b`), `[v6]:PATH` and `ssh://[user@]host[:port]/PATH` too. Anything else is a
    /// local path, returned as typed. Throws when the host is not one `ssh` may be given (`SSHLaunch.validateHost`)
    /// or the remote path has control characters.
    public static func parse(_ argument: String) throws -> FileLocation {
        if argument.hasPrefix("ssh://") {
            let rest = argument.dropFirst("ssh://".count)
            let slash = rest.firstIndex(of: "/") ?? rest.endIndex
            let authority = String(rest[..<slash])
            let path = String(rest[slash...])
            return .remote(host: try SSHLaunch.validateHost("ssh://" + authority), path: try RemotePath.checked(path))
        }
        guard let colon = remoteColon(argument) else { return .local(argument) }
        let host = String(argument[..<colon])
        let path = String(argument[argument.index(after: colon)...])
        return .remote(host: try SSHLaunch.validateHost(host), path: try RemotePath.checked(path))
    }

    /// The colon that ends the host part, or nil for a local path.
    private static func remoteColon(_ argument: String) -> String.Index? {
        if argument.hasPrefix("[") {
            // [v6addr]:path or [user@v6addr]:path
            guard let close = argument.firstIndex(of: "]") else { return nil }
            let after = argument.index(after: close)
            return after < argument.endIndex && argument[after] == ":" ? after : nil
        }
        guard let colon = argument.firstIndex(of: ":"), colon != argument.startIndex else { return nil }
        if let slash = argument.firstIndex(of: "/"), slash < colon { return nil }
        return colon
    }
}

/// POSIX paths on a server (always `/`-separated, never standardized against the Mac's file system).
public enum RemotePath {
    /// Longest remote path accepted.
    public static let maxLength = 4096

    public struct Invalid: Error, CustomStringConvertible, Equatable {
        public var description: String
    }

    /// A path as typed: no control characters, not too long. Empty means the remote home.
    public static func checked(_ path: String) throws -> String {
        guard path.utf8.count <= maxLength else { throw Invalid(description: "remote path is too long") }
        guard !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw Invalid(description: "remote path must not contain control characters")
        }
        return path
    }

    public static func join(_ folder: String, _ name: String) -> String {
        if folder.isEmpty { return name }
        return folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    public static func name(_ path: String) -> String {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        if trimmed == "/" { return "/" }
        return trimmed.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? trimmed
    }

    /// The enclosing folder of an absolute path (`/` for `/` and top-level items).
    public static func parent(_ path: String) -> String {
        let parts = components(path)
        guard parts.count > 1 else { return "/" }
        return "/" + parts.dropLast().joined(separator: "/")
    }

    /// `..` and `.` removed, repeated slashes collapsed (absolute paths only; `..` above `/` stays at `/`).
    public static func normalized(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var result: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = result.popLast(); continue }
            result.append(part)
        }
        return "/" + result.joined(separator: "/")
    }

    public static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// `path` is `folder` or inside it (both absolute, normalized).
    public static func isSameOrInside(_ path: String, _ folder: String) -> Bool {
        let a = components(normalized(path))
        let b = components(normalized(folder))
        return a.count >= b.count && Array(a.prefix(b.count)) == b
    }

    /// A remote pane's path made absolute against the login folder: `""` and `~` are `home`, `~/x` and `x` are inside
    /// it; absolute paths stay as they are (the server resolves `..` and links with `realpath`).
    public static func absolute(_ path: String, home: String) -> String {
        if path.isEmpty || path == "~" { return home }
        if path.hasPrefix("~/") { return join(home, String(path.dropFirst(2))) }
        if !path.hasPrefix("/") { return join(home, path) }
        return path
    }

    /// A path typed into Go to Folder of a remote pane: absolute, `~`/`~/…` (left for the server to resolve), or
    /// relative to `folder`.
    public static func resolve(typed: String, in folder: String) -> String {
        let path = typed.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") { return path }
        return normalized(join(folder, path))
    }
}
