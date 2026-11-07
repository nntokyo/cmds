import Foundation

// Browsing a files pane's folder on the phone, read only (`SyncFeature.filesBrowse`, #26 phase 4;
// docs/internals/sync-protocol.md "Files panes"). The phone names a files pane and an absolute path; the Mac lists that
// folder (`listing`) or sends one of its files (`requestFile` with `path`, the `file` pieces of preview panes). Nothing
// here writes, renames or deletes.

/// One row of a `listing`.
public struct SyncFileEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case file, folder, symlink
        /// Anything else (sockets, devices, pipes), and kinds of newer Macs.
        case other
    }

    public var name: String
    public var kind: Kind
    /// Symbolic links: the link leads to a folder, so the phone opens it like one.
    public var linksToFolder: Bool?
    /// Bytes of files and of links to files.
    public var size: Int64?
    public var modified: Date?

    public init(name: String, kind: Kind, linksToFolder: Bool? = nil, size: Int64? = nil, modified: Date? = nil) {
        self.name = name
        self.kind = kind
        self.linksToFolder = linksToFolder
        self.size = size
        self.modified = modified
    }

    /// The phone opens it as a folder (a folder, or a link to one).
    public var opensAsFolder: Bool { kind == .folder || (kind == .symlink && linksToFolder == true) }

    private enum CodingKeys: String, CodingKey { case name, kind, linksToFolder, size, modified }

    /// Lenient: a kind this phone does not know is `other`; a missing name fails only this entry.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        kind = c.lenientString(.kind).flatMap(Kind.init(rawValue:)) ?? .other
        linksToFolder = c.lenientBool(.linksToFolder)
        size = c.lenientInt(.size).map(Int64.init)
        modified = c.lenientDate(.modified)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(linksToFolder, forKey: .linksToFolder)
        try c.encodeIfPresent(size, forKey: .size)
        // Epoch seconds, like the other dates the phone gets.
        try c.encodeIfPresent(modified?.timeIntervalSince1970, forKey: .modified)
    }
}

extension ClientMessage {
    /// Ask for the contents of a folder of a files pane (Macs that list `SyncFeature.filesBrowse`). `path` absent: the
    /// folder the pane shows. Answered with `listing` (also when the folder cannot be read: `listing.error`).
    public struct RequestListing: Codable, Equatable, Sendable {
        public var paneID: String
        /// Absolute (on the Mac, or on the SSH host of a remote pane).
        public var path: String?

        public init(paneID: String, path: String? = nil) {
            self.paneID = paneID
            self.path = path
        }
    }
}

extension ServerMessage {
    /// A folder of a files pane (answer to `requestListing`): folders first, then by name like the Mac's list, at most
    /// `SyncListing.maxEntries` (`truncated` when there were more). Hidden items only when the pane shows them.
    public struct Listing: Codable, Equatable, Sendable {
        public var paneID: String
        /// The folder listed, absolute and standardized (for a request without a path: the pane's folder). The
        /// requested path when it could not be listed.
        public var path: String
        public var entries: [SyncFileEntry]
        public var truncated: Bool?
        /// Why the folder could not be listed (`SyncListing.Failure` raw values; newer Macs may send others).
        public var error: String?

        public init(paneID: String, path: String, entries: [SyncFileEntry], truncated: Bool? = nil,
                    error: String? = nil) {
            self.paneID = paneID
            self.path = path
            self.entries = entries
            self.truncated = truncated
            self.error = error
        }

        public init(paneID: String, path: String, failure: SyncListing.Failure) {
            self.init(paneID: paneID, path: path, entries: [], error: failure.rawValue)
        }

        /// The known failure, if `error` is one.
        public var failure: SyncListing.Failure? { error.map { SyncListing.Failure(rawValue: $0) ?? .other } }

        private enum CodingKeys: String, CodingKey { case paneID, path, entries, truncated, error }

        /// Lenient: an entry this phone cannot read is dropped, not the whole listing.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            paneID = try c.decode(String.self, forKey: .paneID)
            path = c.lenientString(.path) ?? ""
            let entries = (try? c.decodeIfPresent([JSONValue].self, forKey: .entries)) ?? []
            self.entries = entries.compactMap { try? $0.decode(SyncFileEntry.self) }
            truncated = c.lenientBool(.truncated)
            error = c.lenientString(.error)
        }
    }
}

/// Listing folders and reading files of a files pane for the phone.
public enum SyncListing {
    /// Most entries in one `listing` (folders first, then by name); the rest is left out with `truncated`.
    public static let maxEntries = 2000

    /// Why a `listing` (or a file of a files pane) could not be sent.
    public enum Failure: String, Sendable, CaseIterable {
        /// No such pane.
        case paneNotFound
        /// The pane is not a files pane.
        case notFilesPane
        /// The path is not absolute or not allowed.
        case badPath
        case notFound
        case notAFolder
        /// A file was asked for and the path is a folder, a pipe, a device…
        case notAFile
        case permissionDenied
        /// A pane on an SSH host whose connection is not open on the Mac (the phone never makes one).
        case remoteNotConnected
        /// Anything else.
        case other
    }

    /// The path a request asks for, standardized: `requested` (absolute) or else `paneFolder`. Throws `badPath` for a
    /// relative path, control characters or one that is too long. `..` cannot leave `/`.
    public static func path(requested: String?, paneFolder: String) throws -> String {
        let raw = requested ?? paneFolder
        guard raw.hasPrefix("/"), (try? RemotePath.checked(raw)) != nil else { throw ListingError(.badPath) }
        // Lexically, the same for this Mac and a server (`standardizingPath` would expand `~` and drop `/private`).
        return RemotePath.normalized(raw)
    }

    /// The entries a phone gets from the items of a folder: hidden ones (names starting with a dot, or `isHidden`)
    /// only with `showHidden`, folders and links to folders first, then by name like the Mac's list, at most `limit`.
    public static func entries(_ items: [FileItem], showHidden: Bool, limit: Int = maxEntries,
                               isHidden: (FileItem) -> Bool = { $0.name.hasPrefix(".") },
                               follow: (FileItem) -> FileItem? = { _ in nil }) -> (entries: [SyncFileEntry], truncated: Bool) {
        let shown = items.filter { FileNames.isValid($0.name) && (showHidden || !isHidden($0)) }
        let entries = shown.map { item -> SyncFileEntry in
            switch item.kind {
            case .file:
                return SyncFileEntry(name: item.name, kind: .file, size: item.size, modified: item.modified)
            case .folder:
                return SyncFileEntry(name: item.name, kind: .folder, modified: item.modified)
            case .symlink:
                let target = follow(item)
                return SyncFileEntry(name: item.name, kind: .symlink, linksToFolder: target?.kind == .folder ? true : nil,
                                     size: target?.kind == .file ? target?.size : nil, modified: item.modified)
            case .other:
                return SyncFileEntry(name: item.name, kind: .other, modified: item.modified)
            }
        }
        // Sorted with the Mac list's rules (FileSorting), then mapped back by name (names are unique in a folder).
        let byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = entries.map { FileEntry(name: $0.name, isFolder: $0.opensAsFolder) }
        let sorted = FileSorting.sorted(rows, by: .name, ascending: true).compactMap { byName[$0.name] }
        return (Array(sorted.prefix(limit)), sorted.count > limit)
    }

    /// The failure a file system error stands for.
    public static func failure(for error: Error) -> Failure {
        if let error = error as? ListingError { return error.failure }
        if let error = error as? SFTPError {
            switch error {
            case .disconnected: return .remoteNotConnected
            default: break
            }
            switch error.statusCode {
            case .noSuchFile: return .notFound
            case .permissionDenied: return .permissionDenied
            default: return .other
            }
        }
        if case .posix(let code, _)? = error as? TransferFailure { return failure(errno: code) }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return .notFound
            case NSFileReadNoPermissionError: return .permissionDenied
            default: break
            }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain == NSPOSIXErrorDomain {
                return failure(errno: Int32(underlying.code))
            }
        }
        if nsError.domain == NSPOSIXErrorDomain { return failure(errno: Int32(nsError.code)) }
        return .other
    }

    private static func failure(errno code: Int32) -> Failure {
        switch code {
        case ENOENT: return .notFound
        case ENOTDIR: return .notAFolder
        case EACCES, EPERM: return .permissionDenied
        default: return .other
        }
    }

    /// A `Failure` thrown by the reader.
    public struct ListingError: Error, Equatable {
        public var failure: Failure
        public init(_ failure: Failure) { self.failure = failure }
    }
}

/// Reads folders and files of a files pane for the phone: on this Mac (`local()`) or through the open SFTP connection
/// of a remote pane (`server(_:)`). Calls block (file system, network); never call it on the main thread.
public struct SyncFolderReader {
    public let tree: FileTree
    /// The item at a path, following symbolic links; nil when nothing is there (or the link is broken).
    let follow: (String) throws -> FileItem?
    /// Hidden on the Mac besides dot names (the hidden flag).
    let isHidden: (String) -> Bool
    /// The folder a remote pane shows may still be `~/…` or relative to the home folder.
    let home: String?

    public static func local() -> SyncFolderReader {
        SyncFolderReader(tree: LocalFileTree(), follow: { path in
            var info = stat()
            guard stat(path, &info) == 0 else {
                if errno == ENOENT || errno == ENOTDIR || errno == ELOOP { return nil }
                throw LocalFileTree.errnoFailure(path)
            }
            return LocalFileTree.item(name: (path as NSString).lastPathComponent, info)
        }, isHidden: { path in
            var info = stat()
            return lstat(path, &info) == 0 && info.st_flags & UInt32(UF_HIDDEN) != 0
        }, home: nil)
    }

    public static func server(_ tree: SFTPFileTree) -> SyncFolderReader {
        SyncFolderReader(tree: tree, follow: { path in
            do {
                return SFTPFileTree.item(name: RemotePath.name(path), try tree.client.stat(path))
            } catch let error as SFTPError where error.statusCode == .noSuchFile {
                return nil
            }
        }, isHidden: { _ in false }, home: tree.home)
    }

    /// The standardized path a request asks for (see `SyncListing.path`); a remote pane's folder made absolute first.
    public func path(requested: String?, paneFolder: String) throws -> String {
        var folder = paneFolder
        if let home, !folder.hasPrefix("/") { folder = RemotePath.absolute(folder, home: home) }
        return try SyncListing.path(requested: requested, paneFolder: folder)
    }

    /// The folder at `path` (absolute, standardized) as a `listing`; failures go into `error`.
    public func listing(paneID: String, path: String, showHidden: Bool) -> ServerMessage.Listing {
        do {
            guard let folder = try follow(path) else { throw SyncListing.ListingError(.notFound) }
            guard folder.kind == .folder else { throw SyncListing.ListingError(.notAFolder) }
            let items = try tree.list(path)
            let (entries, truncated) = SyncListing.entries(
                items, showHidden: showHidden,
                isHidden: { $0.name.hasPrefix(".") || isHidden(tree.paths.join(path, $0.name)) },
                follow: { try? follow(tree.paths.join(path, $0.name)) })
            return ServerMessage.Listing(paneID: paneID, path: path, entries: entries, truncated: truncated ? true : nil)
        } catch {
            return ServerMessage.Listing(paneID: paneID, path: path, failure: SyncListing.failure(for: error))
        }
    }

    /// The `file` pieces of the file at `path` (absolute, standardized), each carrying `path`; one `truncated` piece
    /// when it is larger than `SyncFile.maxBytes`. Throws `SyncListing.ListingError` (`notFound`, `notAFile`) for
    /// anything but a file (a folder, a pipe that would block the read, a broken link), or the read's error.
    public func file(paneID: String, path: String) throws -> [ServerMessage.File] {
        guard let item = try follow(path) else { throw SyncListing.ListingError(.notFound) }
        guard item.kind == .file else { throw SyncListing.ListingError(.notAFile) }
        let name = tree.paths.name(path)
        let mime = SyncFile.mimeType(forFileName: name)
        guard item.size <= Int64(SyncFile.maxBytes) else {
            return [SyncFile.truncated(paneID: paneID, name: name, mime: mime, path: path)]
        }
        let reader = try tree.openForReading(path)
        defer { reader.close() }
        var data = Data()
        while true {
            let chunk = try reader.read()
            if chunk.isEmpty { break }
            data.append(chunk)
            // Grew while being read.
            if data.count > SyncFile.maxBytes {
                return [SyncFile.truncated(paneID: paneID, name: name, mime: mime, path: path)]
            }
        }
        return SyncFile.messages(paneID: paneID, name: name, mime: mime, data: data, path: path)
    }
}
