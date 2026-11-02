import Foundation

/// One item as a transfer sees it (the item itself: a symbolic link is a link, not its target).
public struct FileItem: Equatable, Sendable {
    public enum Kind: Sendable, Equatable { case file, folder, symlink, other }

    public var name: String
    public var kind: Kind
    public var size: Int64
    public var modified: Date?
    /// Permission bits (`0o7777`), when known.
    public var permissions: UInt32?

    public init(name: String, kind: Kind, size: Int64 = 0, modified: Date? = nil, permissions: UInt32? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
        self.permissions = permissions
    }
}

/// Reads a file in chunks.
public protocol FileTreeReader: AnyObject {
    /// The next bytes; empty at the end.
    func read() throws -> Data
    func close()
}

/// Writes a file the transfer created itself.
public protocol FileTreeWriter: AnyObject {
    func write(_ data: Data) throws
    /// Flushes and closes; throws when the data did not all arrive.
    func finish() throws
    /// Closes without flushing (cancel / failure).
    func abandon()
}

/// The file operations a transfer needs, on this Mac (`LocalFileTree`) or on a server (`SFTPFileTree`). Paths are
/// absolute within the tree. Calls block; transfers make them on their own threads.
///
/// Nothing here deletes the user's data: `trash` moves an item to the tree's Trash, and `removePart` removes only a
/// transfer's own temporary file (`TransferNames.isPart`).
public protocol FileTree: AnyObject {
    /// The item (not following a final symbolic link), or nil when nothing is there.
    func item(at path: String) throws -> FileItem?
    func list(_ path: String) throws -> [FileItem]
    /// Fails when anything is there already.
    func makeFolder(_ path: String, permissions: UInt32?) throws
    func openForReading(_ path: String) throws -> FileTreeReader
    /// Creates a new file; fails when anything is there already.
    func createFile(_ path: String, permissions: UInt32?) throws -> FileTreeWriter
    /// Fails when `newPath` exists (never overwrites).
    func rename(_ path: String, to newPath: String) throws
    /// To the Trash of this tree (this Mac's, or the server's freedesktop Trash); throws when that is not possible,
    /// and then nothing changed.
    func trash(_ path: String) throws
    /// Removes a transfer's own temporary file (refuses any other name).
    func removePart(_ path: String) throws
    func readLink(_ path: String) throws -> String
    func makeLink(_ path: String, target: String) throws
    /// Best effort: times and permissions of a copy.
    func setAttributes(_ path: String, modified: Date?, permissions: UInt32?)
}

extension FileTree {
    public func exists(_ path: String) -> Bool { (try? item(at: path)) != nil }
}

public struct FileTreeError: Error, CustomStringConvertible, Equatable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// Names a transfer uses for its own temporary files: `.cmds-part-<8 hex>-<name>` next to the final item, so a
/// half-written file never carries the real name and a cancelled transfer removes only what it wrote.
public enum TransferNames {
    public static let partPrefix = ".cmds-part-"

    public static func part(for name: String) -> String {
        let random = (0..<4).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        // Keep within 255 bytes.
        var base = name
        while (partPrefix + random + "-" + base).utf8.count > 255 { base.removeFirst() }
        return partPrefix + random + "-" + base
    }

    public static func isPart(_ name: String) -> Bool {
        guard name.hasPrefix(partPrefix) else { return false }
        let rest = name.dropFirst(partPrefix.count)
        guard rest.count > 9 else { return false }
        let hex = rest.prefix(8)
        return hex.allSatisfy(\.isHexDigit) && rest[rest.index(rest.startIndex, offsetBy: 8)] == "-"
    }
}

// MARK: - This Mac

/// The Mac's file system for transfers.
public final class LocalFileTree: FileTree {
    /// Moves an item to the Trash. Tests use a folder of their own.
    public var trashItem: (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
    public static let chunkSize = 256 * 1024

    public init() {}

    public func item(at path: String) throws -> FileItem? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw FileTreeError(Self.errnoText(path))
        }
        return Self.item(name: (path as NSString).lastPathComponent, info)
    }

    static func item(name: String, _ info: stat) -> FileItem {
        let kind: FileItem.Kind
        switch info.st_mode & S_IFMT {
        case S_IFDIR: kind = .folder
        case S_IFREG: kind = .file
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                            + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        return FileItem(name: name, kind: kind, size: kind == .file ? Int64(info.st_size) : 0, modified: modified,
                        permissions: UInt32(info.st_mode & 0o7777))
    }

    public func list(_ path: String) throws -> [FileItem] {
        let names = try FileManager.default.contentsOfDirectory(atPath: path)
        return names.compactMap { try? item(at: (path as NSString).appendingPathComponent($0)) }
    }

    public func makeFolder(_ path: String, permissions: UInt32?) throws {
        guard mkdir(path, mode_t(permissions ?? 0o755)) == 0 else { throw FileTreeError(Self.errnoText(path)) }
    }

    public func openForReading(_ path: String) throws -> FileTreeReader {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw FileTreeError("cannot open \(path)") }
        return Reader(handle)
    }

    public func createFile(_ path: String, permissions: UInt32?) throws -> FileTreeWriter {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(permissions ?? 0o644))
        guard fd >= 0 else { throw FileTreeError(Self.errnoText(path)) }
        return Writer(FileHandle(fileDescriptor: fd, closeOnDealloc: true))
    }

    public func rename(_ path: String, to newPath: String) throws {
        // renamex_np with RENAME_EXCL: fails instead of replacing.
        guard renamex_np(path, newPath, UInt32(RENAME_EXCL)) == 0 else { throw FileTreeError(Self.errnoText(newPath)) }
    }

    public func trash(_ path: String) throws {
        try trashItem(URL(fileURLWithPath: path))
    }

    public func removePart(_ path: String) throws {
        guard TransferNames.isPart((path as NSString).lastPathComponent) else {
            throw FileTreeError("refusing to remove \(path)")
        }
        guard unlink(path) == 0 || errno == ENOENT else { throw FileTreeError(Self.errnoText(path)) }
    }

    public func readLink(_ path: String) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    public func makeLink(_ path: String, target: String) throws {
        guard symlink(target, path) == 0 else { throw FileTreeError(Self.errnoText(path)) }
    }

    public func setAttributes(_ path: String, modified: Date?, permissions: UInt32?) {
        var attributes: [FileAttributeKey: Any] = [:]
        if let modified { attributes[.modificationDate] = modified }
        if let permissions { attributes[.posixPermissions] = NSNumber(value: permissions & 0o7777) }
        guard !attributes.isEmpty else { return }
        try? FileManager.default.setAttributes(attributes, ofItemAtPath: path)
    }

    static func errnoText(_ path: String) -> String {
        "\(String(cString: strerror(errno))) (\((path as NSString).lastPathComponent))"
    }

    private final class Reader: FileTreeReader {
        let handle: FileHandle
        init(_ handle: FileHandle) { self.handle = handle }
        func read() throws -> Data { try handle.read(upToCount: LocalFileTree.chunkSize) ?? Data() }
        func close() { try? handle.close() }
    }

    private final class Writer: FileTreeWriter {
        let handle: FileHandle
        init(_ handle: FileHandle) { self.handle = handle }
        func write(_ data: Data) throws { try handle.write(contentsOf: data) }
        func finish() throws {
            try handle.synchronize()
            try handle.close()
        }
        func abandon() { try? handle.close() }
    }
}

// MARK: - A server

/// A server's files over SFTP (`SFTPClient`). Reads and writes keep several requests in flight, so a transfer is not
/// limited by the round trip time.
public final class SFTPFileTree: FileTree {
    public let client: SFTPClient
    /// The login (home) folder, absolute: where the Trash is.
    public let home: String
    /// The time `trash` writes into `.trashinfo` (tests fix it).
    public var now: () -> Date = Date.init

    /// Bytes per read or write request (OpenSSH's sftp client uses 32 KiB).
    public static let chunkSize: UInt32 = 32 * 1024
    /// Requests in flight per file.
    public static let requestsInFlight = 16

    public init(client: SFTPClient, home: String) {
        self.client = client
        self.home = home
    }

    public func item(at path: String) throws -> FileItem? {
        do {
            return Self.item(name: RemotePath.name(path), try client.lstat(path))
        } catch let error as SFTPError where error.statusCode == .noSuchFile {
            return nil
        }
    }

    static func item(name: String, _ attributes: SFTP.Attributes) -> FileItem {
        let kind: FileItem.Kind
        switch attributes.fileType {
        case .folder: kind = .folder
        case .file, .unknown: kind = .file
        case .symlink: kind = .symlink
        case .other: kind = .other
        }
        return FileItem(name: name, kind: kind, size: kind == .file ? Int64(attributes.size ?? 0) : 0,
                        modified: attributes.modified, permissions: attributes.permissions.map { $0 & 0o7777 })
    }

    public func list(_ path: String) throws -> [FileItem] {
        try client.list(path).map { Self.item(name: $0.name, $0.attributes) }
    }

    public func makeFolder(_ path: String, permissions: UInt32?) throws {
        try client.mkdir(path, permissions: permissions)
    }

    public func openForReading(_ path: String) throws -> FileTreeReader {
        let handle = try client.open(path, flags: .read)
        return Reader(client: client, handle: handle)
    }

    public func createFile(_ path: String, permissions: UInt32?) throws -> FileTreeWriter {
        let handle = try client.open(path, flags: [.write, .create, .exclusive],
                                     attributes: SFTP.Attributes(permissions: permissions ?? 0o644))
        return Writer(client: client, handle: handle)
    }

    public func rename(_ path: String, to newPath: String) throws {
        try client.rename(path, to: newPath)
    }

    public func trash(_ path: String) throws {
        try RemoteTrash(tree: self).trash(path, date: now())
    }

    public func removePart(_ path: String) throws {
        guard TransferNames.isPart(RemotePath.name(path)) else { throw FileTreeError("refusing to remove \(path)") }
        do {
            try client.remove(path)
        } catch let error as SFTPError where error.statusCode == .noSuchFile {}
    }

    public func readLink(_ path: String) throws -> String { try client.readlink(path) }

    public func makeLink(_ path: String, target: String) throws {
        try client.symlink(target: target, linkPath: path)
    }

    public func setAttributes(_ path: String, modified: Date?, permissions: UInt32?) {
        var attributes = SFTP.Attributes(permissions: permissions)
        if let modified {
            let seconds = UInt32(clamping: Int64(modified.timeIntervalSince1970.rounded(.down)))
            attributes.accessTime = seconds
            attributes.modificationTime = seconds
        }
        try? client.setstat(path, attributes)
    }

    /// Reads ahead: up to `requestsInFlight` chunks requested, consumed in order. A short reply (allowed by the
    /// protocol) is completed with plain reads before the next chunk.
    private final class Reader: FileTreeReader {
        let client: SFTPClient
        let handle: Data
        var queue: [(offset: UInt64, request: SFTPClient.Pending)] = []
        var nextOffset: UInt64 = 0
        var atEnd = false
        var closed = false

        init(client: SFTPClient, handle: Data) {
            self.client = client
            self.handle = handle
        }

        func read() throws -> Data {
            guard !atEnd else { return Data() }
            while queue.count < SFTPFileTree.requestsInFlight {
                queue.append((nextOffset, client.read(handle, offset: nextOffset, length: SFTPFileTree.chunkSize)))
                nextOffset += UInt64(SFTPFileTree.chunkSize)
            }
            let (offset, request) = queue.removeFirst()
            var data = try chunk(request.wait())
            if data.isEmpty {
                atEnd = true
                return Data()
            }
            // Short reply: fetch the rest of this chunk directly.
            while data.count < Int(SFTPFileTree.chunkSize) {
                let more = try chunk(client.read(handle, offset: offset + UInt64(data.count),
                                                 length: SFTPFileTree.chunkSize - UInt32(data.count)).wait())
                if more.isEmpty {
                    atEnd = true
                    break
                }
                data += more
            }
            return data
        }

        private func chunk(_ response: SFTP.Response) throws -> Data {
            switch response {
            case .data(_, let data): return data
            case .status(_, let code, _) where code == SFTP.StatusCode.eof.rawValue: return Data()
            case .status(_, let code, let message): throw SFTPError.status(code: code, message: message)
            default: throw SFTPError.protocolError("unexpected reply to READ")
            }
        }

        func close() {
            guard !closed else { return }
            closed = true
            // Replies still on their way are dropped by the client.
            _ = try? client.close(handle)
        }

        deinit { close() }
    }

    /// Writes ahead: up to `requestsInFlight` chunks unanswered; `finish` waits for all of them.
    private final class Writer: FileTreeWriter {
        let client: SFTPClient
        let handle: Data
        var queue: [SFTPClient.Pending] = []
        var offset: UInt64 = 0
        var closed = false

        init(client: SFTPClient, handle: Data) {
            self.client = client
            self.handle = handle
        }

        func write(_ data: Data) throws {
            var start = data.startIndex
            while start < data.endIndex {
                let end = min(start + Int(SFTPFileTree.chunkSize), data.endIndex)
                let piece = data[start..<end]
                if queue.count >= SFTPFileTree.requestsInFlight {
                    try SFTPClient.expectOK(queue.removeFirst().wait())
                }
                queue.append(client.write(handle, offset: offset, data: Data(piece)))
                offset += UInt64(piece.count)
                start = end
            }
        }

        func finish() throws {
            defer { closeHandle() }
            while !queue.isEmpty { try SFTPClient.expectOK(queue.removeFirst().wait()) }
            closed = true
            try client.close(handle)
        }

        func abandon() { closeHandle() }

        private func closeHandle() {
            guard !closed else { return }
            closed = true
            for request in queue { _ = try? request.wait() }
            queue.removeAll()
            _ = try? client.close(handle)
        }
    }
}
