import Foundation

/// `.sync` (docs/guide/files.md "Comparing and syncing folders"): the actions of a `FolderSync` plan between two
/// folders, the job's source (left) and destination (right). Rules: TransferJob.swift's header.
extension TransferJob {
    /// Runs the plan's actions not done yet. Each is logged with the side it changed; failures are logged and the
    /// action is retried by Retry. Throws only to stop the job.
    func runSync(_ request: SyncRequest, left: FileTree, right: FileTree) throws {
        let pending = request.actions.indices.filter { !isCompleted($0) }
        updateProgress { $0.counting = true }
        var bytes: Int64 = 0
        for index in pending {
            let action = request.actions[index]
            guard case .copy(let to) = action.kind else { continue }
            let from = to.other
            let tree = from == .left ? left : right
            bytes += try size(of: tree.paths.join(request.root(from), action.path(from)), in: tree)
        }
        setTotals(items: pending.count, bytes: bytes)
        for index in pending {
            try checkpoint()
            if try runSyncAction(index, request, left: left, right: right) { markCompleted(index) }
        }
    }

    /// One action of a sync; true when it needs no retry (done, or left alone for good).
    func runSyncAction(_ index: Int, _ request: SyncRequest, left: FileTree, right: FileTree) throws -> Bool {
        defer { updateProgress { $0.itemsDone += 1 } }
        let action = request.actions[index]
        func tree(_ side: FolderSync.Side) -> FileTree { side == .left ? left : right }
        func path(_ side: FolderSync.Side) -> String { tree(side).paths.join(request.root(side), action.path(side)) }
        let shown = action.path
        let side = action.changes
        let target = path(side)
        let targetTree = tree(side)
        setSyncSide(side)
        var existing: FileItem?
        guard try attempt(shown, { existing = try targetTree.item(at: target) }) else { return false }
        let trashedBefore = isSyncTrashed(index)

        guard case .copy = action.kind else {
            guard FolderSync.matches(existing, action.item(side)) else {
                record(shown, .failed(.changedSinceCompare))
                return true
            }
            guard try attempt(shown, { try targetTree.trash(target) }) else { return false }
            record(shown, .trashed)
            return true
        }

        let from = side.other
        let source = path(from)
        let sourceTree = tree(from)
        var found: FileItem?
        guard try attempt(shown, { found = try sourceTree.item(at: source) }) else { return false }
        guard let item = found else {
            record(shown, .failed(.noSuchItem))
            return false
        }
        guard item.kind == .file || item.kind == .folder else {
            record(shown, .notCopied)
            return true
        }
        let merging = item.kind == .folder && existing?.kind == .folder && ownFolder(target)
        guard merging || FolderSync.matches(existing, trashedBefore ? nil : action.item(side)) else {
            record(shown, .failed(.changedSinceCompare))
            addBytesDone(item.kind == .file ? item.size : 0)
            return true
        }
        let outcome: Outcome = merging ? .merged : (existing != nil || trashedBefore) ? .replaced : .copied
        let failuresBefore = failureCount()
        do {
            if let existing, !merging {
                // What is there goes to its side's Trash; a file over a file only once the new one is complete.
                let trashOld = {
                    try self.trashExisting(target, in: targetTree)
                    self.markSyncTrashed(index)
                }
                if existing.kind == .file, item.kind == .file {
                    _ = try attempt(shown) {
                        try copyFile(item, from: source, in: sourceTree, to: target, in: targetTree, relative: shown,
                                     beforeRename: trashOld)
                    }
                } else {
                    guard try attempt(shown, trashOld) else { return false }
                    try copy(item, from: source, in: sourceTree, to: target, in: targetTree, relative: shown,
                             merging: false, isTopLevel: true)
                }
            } else {
                try copy(item, from: source, in: sourceTree, to: target, in: targetTree, relative: shown,
                         merging: merging, isTopLevel: true)
            }
        } catch is Cancelled {
            trashFolderOnCancel(target, created: item.kind == .folder && !merging, in: targetTree)
            throw Cancelled()
        }
        guard failureCount() == failuresBefore else { return false }
        record(shown, outcome)
        return true
    }
}

extension TransferJob.SyncRequest {
    public func location(_ side: FolderSync.Side) -> FileLocation { side == .left ? left : right }
    public func root(_ side: FolderSync.Side) -> String { location(side).path }
}
