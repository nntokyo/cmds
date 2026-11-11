import Foundation

/// A browser pane that reloads when files in a folder change (#252): its settings, which pages and paths count, the
/// request of `browser.watch` and the debounce. The watcher itself (FSEvents) is the app's
/// (`Browser/BrowserPane+Watch.swift`).
public struct BrowserWatch: Equatable, Sendable {
    /// The folder watched (absolute, standardized).
    public var folder: String
    /// Reload remote (non-local) pages too; off by default, so a page on the web never reloads for local edits.
    public var remote: Bool

    public init(folder: String, remote: Bool = false) {
        self.folder = folder
        self.remote = remote
    }

    /// Quiet time after the last change before the page reloads (a save often writes several files).
    public static let debounce: TimeInterval = 0.3
    /// A folder that keeps changing (a build writing files) still reloads at least this often.
    public static let maxDelay: TimeInterval = 2

    /// Folder names whose contents never reload the page: dependencies and build output, which tools rewrite on their
    /// own (names starting with a dot, `.git` among them, are left out too).
    public static let ignoredFolders: Set<String> = [
        "node_modules", "build", "DerivedData", "Pods", "target", "__pycache__", "bower_components",
    ]

    /// Whether the page reloads for this pane's watch: local pages always, remote ones only with `remote`.
    public func reloads(_ url: URL?) -> Bool {
        guard let url else { return false }
        return Self.isLocalPage(url) || (remote && ["http", "https"].contains(url.scheme?.lowercased() ?? ""))
    }

    /// A page from this Mac: `file://`, or http(s) on a loopback host (`localhost`, `*.localhost`, `127.x.x.x`, `::1`,
    /// `0.0.0.0`).
    public static func isLocalPage(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "file": return true
        case "http", "https":
            guard var host = url.host?.lowercased() else { return false }
            if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "0.0.0.0" { return true }
            let parts = host.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { UInt8($0) != nil }
        default: return false
        }
    }

    /// Whether a change at `path` is left out: inside a dot folder or one of `ignoredFolders` below `folder`, a dot
    /// file, or an editor backup (`name~`). Inside `keep` (the folder of the `file://` page shown) only the folders
    /// below `keep` count, so a page served from `build/` still reloads for its files (not for its own
    /// `node_modules`). Paths outside `folder` are left out. For a folder's own event (`isFolder`: its entries or
    /// metadata changed, which comes with the entries' own events anyway), the watched folder, `keep` and ignored
    /// folders themselves are left out too.
    public static func isIgnored(_ path: String, folder: String, keep: String? = nil, isFolder: Bool = false) -> Bool {
        guard let relative = relativePath(path, in: folder) else { return true }
        guard let name = relative.split(separator: "/").last else { return true }  // the watched folder itself
        if name.hasPrefix(".") || name.hasSuffix("~") { return true }
        var components = (keep.flatMap { relativePath(path, in: $0) } ?? relative).split(separator: "/")
        guard !components.isEmpty else { return true }  // `keep` itself
        if !isFolder { components.removeLast() }
        return components.contains { $0.hasPrefix(".") || ignoredFolders.contains(String($0)) }
    }

    /// `path` below `folder` ("" for the folder itself), nil when it is not inside it.
    static func relativePath(_ path: String, in folder: String) -> String? {
        let base = folder.hasSuffix("/") && folder.count > 1 ? String(folder.dropLast()) : folder
        if path == base { return "" }
        let prefix = base == "/" ? "/" : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// The folder of a `file://` page (nil for other pages).
    public static func pageFolder(_ url: URL?) -> String? {
        guard let url, url.isFileURL else { return nil }
        return url.deletingLastPathComponent().standardizedFileURL.path
    }

    /// API and CLI form: `{"on", "folder"?, "remote", "active"?}` (`active`: watching now; a pane off screen or on a
    /// page that does not reload is not).
    public static func json(_ watch: BrowserWatch?, active: Bool? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["on": .bool(watch != nil), "remote": .bool(watch?.remote ?? false)]
        if let watch { object["folder"] = .string(watch.folder) }
        if let active { object["active"] = .bool(active) }
        return .object(object)
    }

    /// One line for `cmds browser watch`.
    public static func summary(_ json: JSONValue) -> String {
        guard json["on"]?.boolValue == true, let folder = json["folder"]?.stringValue else { return "off" }
        var line = "watching \(folder)"
        if json["remote"]?.boolValue == true { line += " (remote pages too)" }
        if json["active"]?.boolValue == false { line += " (paused: pane not on screen or page not local)" }
        return line
    }
}

/// What `browser.watch` asks for: nothing (report), off, or on with a folder (default: the workspace's folder).
public struct BrowserWatchChange: Equatable, Sendable {
    public var off: Bool
    /// An absolute folder; nil keeps the current one (or the default).
    public var folder: String?
    public var remote: Bool?

    public init(off: Bool = false, folder: String? = nil, remote: Bool? = nil) {
        self.off = off
        self.folder = folder
        self.remote = remote
    }

    /// `off?`, `dir?` (absolute), `remote?`, `on?` (true: turn on with the default folder). `pane`/`workspace` are
    /// ignored here.
    public init(params: JSONValue?) throws {
        let values = RequestParams(params)
        let on = try values.bool("on")
        self.init(off: try values.bool("off") ?? (on == false), folder: try values.string("dir"),
                  remote: try values.bool("remote"))
        if on == true { turnsOn = true }
        if off, folder != nil || remote != nil { throw RPCError.invalidParams("off cannot be combined with dir or remote") }
        if let folder {
            guard folder.hasPrefix("/") else { throw RPCError.invalidParams("dir must be an absolute path") }
            self.folder = URL(fileURLWithPath: folder).standardizedFileURL.path
        }
    }

    /// `on: true` was given (turn on with the default folder even without `dir`).
    public var turnsOn = false

    /// Nothing asked: just report.
    public var isQuery: Bool { !off && folder == nil && remote == nil && !turnsOn }

    public var params: [String: JSONValue?] {
        var result: [String: JSONValue?] = [:]
        if off { result["off"] = .bool(true) }
        if let folder { result["dir"] = .string(folder) }
        if let remote { result["remote"] = .bool(remote) }
        if turnsOn { result["on"] = .bool(true) }
        return result
    }

    /// The watch after this change. `defaultFolder` is used when turning on without a folder; nil then is an error.
    public func applied(to current: BrowserWatch?, defaultFolder: String?) throws -> BrowserWatch? {
        if off { return nil }
        if isQuery { return current }
        guard let folder = folder ?? current?.folder ?? defaultFolder else {
            throw RPCError.invalidParams("no folder to watch: give dir (the workspace has no local folder)")
        }
        return BrowserWatch(folder: folder, remote: remote ?? current?.remote ?? false)
    }
}

/// Trailing debounce with a ceiling: a reload `BrowserWatch.debounce` after the last change, but no later than
/// `BrowserWatch.maxDelay` after the first one not yet reloaded for.
public struct WatchDebounce: Equatable, Sendable {
    public var debounce: TimeInterval
    public var maxDelay: TimeInterval
    /// The first change since the last reload.
    public private(set) var firstPending: Date?

    public init(debounce: TimeInterval = BrowserWatch.debounce, maxDelay: TimeInterval = BrowserWatch.maxDelay) {
        self.debounce = debounce
        self.maxDelay = maxDelay
    }

    /// A change at `now`: when to reload (move the timer there).
    public mutating func change(at now: Date) -> Date {
        let first = firstPending ?? now
        firstPending = first
        return min(now.addingTimeInterval(debounce), first.addingTimeInterval(maxDelay))
    }

    /// The reload happened (or was dropped).
    public mutating func reset() { firstPending = nil }
}
