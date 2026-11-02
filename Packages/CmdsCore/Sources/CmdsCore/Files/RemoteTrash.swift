import Foundation

/// Move to Trash on a server (docs/guide/files.md "Folders on SSH hosts"): cmds never deletes anything there. Items go
/// to the freedesktop.org Trash of the login user, `~/.local/share/Trash/files`, with a `.trashinfo` in `info` that
/// records where they came from, so `gio trash --list`, `trash-cli` (`trash-restore`) or a desktop file manager on the
/// server can list and restore them.
///
/// It is a rename: an item on another file system than the home folder cannot go there, and is then left where it
/// is (the operation fails; nothing is deleted).
public struct RemoteTrash {
    let tree: SFTPFileTree

    public static let relativeFolder = ".local/share/Trash"
    /// The Trash folders cmds makes, and the `.trashinfo` files it writes, are the login user's only.
    static let folderPermissions: UInt32 = 0o700
    static let infoPermissions: UInt32 = 0o600

    public var folder: String { RemotePath.join(tree.home, Self.relativeFolder) }

    /// Moves `path` into the Trash; returns its name in `Trash/files`.
    @discardableResult
    public func trash(_ path: String, date: Date) throws -> String {
        let source = RemotePath.normalized(path)
        guard !RemotePath.isSameOrInside(folder, source) else {
            throw TransferFailure.trashItself
        }
        guard !RemotePath.isSameOrInside(source, folder) else {
            throw TransferFailure.alreadyInTrash
        }
        let files = RemotePath.join(folder, "files")
        let info = RemotePath.join(folder, "info")
        try makeFolders([RemotePath.join(tree.home, ".local"), RemotePath.join(tree.home, ".local/share"), folder, files, info])
        let original = RemotePath.name(source)
        let name = original.isEmpty ? "item" : original
        let taken = { (candidate: String) in
            tree.exists(RemotePath.join(files, candidate)) || tree.exists(RemotePath.join(info, candidate + ".trashinfo"))
        }
        let candidate = taken(name) ? FileNames.keepBoth(name, isFolder: false, taken: taken) : name
        // The .trashinfo first (exclusive create reserves the name), as the specification asks.
        let infoPath = RemotePath.join(info, candidate + ".trashinfo")
        let writer = try tree.createFile(infoPath, permissions: Self.infoPermissions)
        do {
            try writer.write(Data(Self.trashInfo(path: source, date: date).utf8))
            try writer.finish()
        } catch {
            writer.abandon()
            try? tree.client.remove(infoPath)
            throw error
        }
        do {
            try tree.rename(source, to: RemotePath.join(files, candidate))
        } catch {
            // Our own .trashinfo, written a moment ago; the item itself was not touched.
            try? tree.client.remove(infoPath)
            throw TransferFailure.serverTrashFailed(name: original, TransferFailure(error))
        }
        return candidate
    }

    private func makeFolders(_ paths: [String]) throws {
        for path in paths {
            if let item = try tree.item(at: path) {
                guard item.kind == .folder || item.kind == .symlink else {
                    throw TransferFailure.trashNotAFolder(path)
                }
                continue
            }
            try tree.makeFolder(path, permissions: Self.folderPermissions)
        }
    }

    /// The `.trashinfo` text: `Path` percent-encoded (slashes kept), `DeletionDate` in local time without a zone.
    public static func trashInfo(path: String, date: Date, timeZone: TimeZone = .current) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        allowed.insert(charactersIn: "/-_.~")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return "[Trash Info]\nPath=\(encoded)\nDeletionDate=\(formatter.string(from: date))\n"
    }
}
