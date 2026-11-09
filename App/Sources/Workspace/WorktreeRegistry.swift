import Foundation
import CmdsCore

/// The worktrees cmds created (`worktrees.json` in the support directory, `WorktreeStore`). Only these are ever offered
/// for removal; a worktree made with `git worktree add` or another tool never gets a record.
@MainActor
final class WorktreeRegistry {
    static let shared = WorktreeRegistry()

    private(set) var records: [WorktreeRecord]
    private var saveBlocked = false
    private let url = WorktreeStore.url()

    private init() {
        let loaded = WorktreeStore.load(from: url)
        records = loaded.records
        saveBlocked = loaded.saveBlocked
        if let error = loaded.error {
            if let moved = loaded.movedAside {
                NSLog("cmds: could not read the worktree list (\(error)); moved it to \(moved.path)")
            } else {
                NSLog("cmds: could not read the worktree list (\(error)); not saving it this run")
            }
        }
    }

    /// The record of the worktree at `path` (canonical), if cmds created it.
    func record(at path: String) -> WorktreeRecord? {
        records.first { $0.path == path }
    }

    /// The record of the worktree a local directory is in, if cmds created it. Reads only the file system.
    func record(containing directory: String) -> WorktreeRecord? {
        guard !records.isEmpty, let root = WorktreePaths.workingTreeRoot(of: directory) else { return nil }
        return record(at: root)
    }

    func add(_ record: WorktreeRecord) {
        records.removeAll { $0.path == record.path }
        records.append(record)
        save()
    }

    func remove(_ record: WorktreeRecord) {
        records.removeAll { $0.path == record.path }
        save()
    }

    private func save() {
        guard !saveBlocked else { return }
        do {
            try WorktreeStore.save(records, to: url)
        } catch {
            NSLog("cmds: failed to save the worktree list: \(error)")
        }
    }
}
