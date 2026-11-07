import Foundation

/// `.save`: an edited copy on this Mac goes over the server's file it came from (RemoteEdit.swift,
/// docs/internals/files-sftp.md "Editing a server's file"). Rules: TransferJob.swift's header.
extension TransferJob {
    /// Uploads the edited copy over `request.name` in the destination folder, after checking that the server's file is
    /// still `request.base` (or asking what to do when it is not). Failures are logged; throws only to stop the job.
    func runSave(_ request: SaveRequest, from localTree: FileTree, to tree: FileTree) throws {
        let name = request.name
        let copy = sources[0].path
        let folder = destination.path
        let target = tree.paths.join(folder, name)
        defer { updateProgress { $0.itemsDone = 1 } }
        guard let local = try localTree.item(at: copy), local.kind == .file else {
            record(name, .failed(.noSuchItem))
            return
        }
        updateProgress {
            $0.itemsTotal = 1
            $0.bytesTotal = local.size
        }
        let current = try tree.item(at: target)
        var path = target
        var outcome: Outcome = .saved
        switch request.base.change(to: current) {
        case .unchanged:
            break
        case .notAFile:
            record(name, .failed(.notAFile(name: name)))
            return
        case .changed, .missing:
            // Nobody to ask: upload nothing and keep the copy (Skip would replace it with the server's file).
            if policy == .ask, onConflict == nil { throw StopRequested() }
            switch try resolve(name: name, isFolder: false) {
            case .stop:
                throw StopRequested()
            case .replace:
                break
            case .skip:
                // Keep theirs: the server's file into the copy (nothing to take when it is gone).
                guard let current else {
                    record(name, .skipped)
                    return
                }
                _ = try attempt(name) {
                    try download(target, item: current, into: copy, in: localTree, from: tree,
                                 permissions: local.permissions)
                }
                return
            case .keepBoth:
                let newName = keepBothName(name, isFolder: false, in: folder, tree: tree)
                path = tree.paths.join(folder, newName)
                outcome = .keptBoth(newName)
            }
        }
        // Keep mine replaces what is there; after Keep Both, or when the file is gone, the name must be free.
        let replacing = outcome == .saved && current != nil
        _ = try attempt(name) {
            let written = try upload(copy, from: localTree, to: path, in: tree, replacing: replacing,
                                     permissions: current?.permissions ?? local.permissions)
            if written.replacedThroughTrash { outcome = .replaced }
            let version = try tree.item(at: path).map(RemoteFileVersion.init)
                ?? RemoteFileVersion(size: written.size, modified: nil)
            setSaved(SaveResult(name: tree.paths.name(path), version: version, contentHash: written.hash,
                                      keptTheirs: false))
            record(name, outcome)
        }
    }

    private struct Uploaded {
        var size: Int64
        var hash: String
        /// The server cannot rename over a file: its file went to its Trash first.
        var replacedThroughTrash = false
    }

    /// Writes the copy to a part file next to `path` (with `permissions`), then puts it in place: over the file there
    /// in one step when `replacing` (or through the server's Trash when the server cannot), else only if the name is
    /// still free.
    private func upload(_ copy: String, from localTree: FileTree, to path: String, in tree: FileTree, replacing: Bool,
                        permissions: UInt32?) throws -> Uploaded {
        let name = tree.paths.name(path)
        let part = tree.paths.join(tree.paths.parent(path), TransferNames.part(for: name))
        let entry = TransferPartJournal.Entry(host: destination.host, path: part)
        var hash = ContentHash()
        let size = try stream(copy, from: localTree, to: part, in: tree, entry: entry,
                              permissions: (permissions ?? 0o644) | 0o600) { hash.update($0) }
        tree.setAttributes(part, modified: nil, permissions: permissions)
        var uploaded = Uploaded(size: size, hash: hash.finalize())
        do {
            if replacing {
                do {
                    try tree.renameReplacing(part, to: path)
                } catch let error as SFTPError where error.statusCode == .unsupported {
                    try trashExisting(path, in: tree)
                    try tree.rename(part, to: path)
                    uploaded.replacedThroughTrash = true
                }
            } else {
                do {
                    try tree.rename(part, to: path)
                } catch {
                    throw TransferFailure.appeared(name: name, TransferFailure(error))
                }
            }
            partJournal?.remove(entry)
        } catch {
            removePart(entry, from: tree)
            throw error
        }
        return uploaded
    }

    /// Keep theirs: the server's file into the copy (a part file next to it, renamed over it).
    private func download(_ path: String, item: FileItem, into copy: String, in localTree: FileTree, from tree: FileTree,
                          permissions: UInt32?) throws {
        let name = localTree.paths.name(copy)
        let part = localTree.paths.join(localTree.paths.parent(copy), TransferNames.part(for: name))
        let entry = TransferPartJournal.Entry(host: nil, path: part)
        updateProgress {
            $0.bytesDone = 0
            $0.bytesTotal = item.size
        }
        var hash = ContentHash()
        _ = try stream(path, from: tree, to: part, in: localTree, entry: entry, permissions: permissions ?? 0o644) {
            hash.update($0)
        }
        do {
            try localTree.renameReplacing(part, to: copy)
            partJournal?.remove(entry)
        } catch {
            removePart(entry, from: localTree)
            throw error
        }
        setSaved(SaveResult(name: tree.paths.name(path), version: RemoteFileVersion(item),
                                  contentHash: hash.finalize(), keptTheirs: true))
        record(tree.paths.name(path), .keptTheirs)
    }
}
