import Foundation

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
