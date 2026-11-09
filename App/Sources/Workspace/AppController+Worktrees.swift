import AppKit
import CmdsCore

/// Worktree workspaces (docs/guide/workspaces-and-panes.md "Worktree workspaces", #172): a workspace in a new git
/// worktree, Show Changes, and removing the worktree when its workspace closes. git always runs off the main thread
/// (`Worktrees` blocks); only the results come back here. Failures are `WorktreeError`s (the socket API sends their
/// English `description`, the UI its own text) or `RPCError`s.
extension AppController {
    /// `cmds new --worktree`: creates the branch and worktree from `directory`'s repository, remembers it in
    /// `WorktreeRegistry` and opens a workspace there. Returns the workspace and a warning when `git fetch` failed.
    func createWorktreeWorkspace(from directory: String, request: Worktrees.Request, title: String? = nil,
                                 command: String? = nil, account: ClaudeAccount? = nil) async throws
        -> (info: WorkspaceInfo, warning: String?) {
        let directory = (directory as NSString).expandingTildeInPath
        let creation = try await Self.git { try Worktrees.create(request, from: directory) }
        WorktreeRegistry.shared.add(creation.record)
        let info = createWorkspace(title: title, cwd: creation.record.path, command: command, account: account)
        workspace(id: info.id)?.worktreePath = creation.record.path
        return (try workspaceInfo(id: info.id), creation.fetchWarning)
    }

    // MARK: - Show Changes

    /// Folder of the diff Show Changes writes for a workspace (`$TMPDIR/cmds-changes/<workspace>`, replaced each time).
    static func changesFolder(workspaceID: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cmds-changes", isDirectory: true)
            .appendingPathComponent(workspaceID, isDirectory: true)
    }

    /// Show Changes: the workspace's branch compared with its base (the worktree's for one cmds created, else the
    /// repository's default branch) as a diff preview, in the preview pane already showing it, else in a new one split
    /// to the right of the focused pane. The keyboard stays where it is.
    @discardableResult
    func showChanges(workspaceID: String?) async throws -> (pane: PaneInfo, path: String) {
        let workspace = try resolveWorkspace(workspaceID)
        guard !workspace.isRemote, let directory = workspace.worktreePath ?? workspace.workingDirectory else {
            throw RPCError.invalidParams("Show Changes needs a local folder (workspace \(workspace.id))")
        }
        let base = workspace.createdWorktree?.base
        let changes = try await Self.git { try Worktrees.changes(in: directory, base: base) }

        let folder = Self.changesFolder(workspaceID: workspace.id)
        let name = (changes.branch ?? (changes.root as NSString).lastPathComponent).replacingOccurrences(of: "/", with: "-")
        let file = folder.appendingPathComponent("\(name) changes.diff")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(changes.text.utf8).write(to: file, options: .atomic)
        } catch {
            throw RPCError(code: 500, message: "cannot write the diff: \(error.localizedDescription)")
        }
        // The workspace may have closed while git ran.
        let current = try resolveWorkspace(workspace.id)
        if let existing = current.orderedPanes.first(where: { pane in
            pane.preview.map { $0.path.hasPrefix(folder.path + "/") } ?? false
        }), let preview = existing.preview {
            preview.open(path: file.path, format: .diff)
            emit(.pane(workspaceID: current.id, paneID: existing.id))
            return (try paneInfo(id: existing.id), file.path)
        }
        guard let source = current.focusedPane ?? current.orderedPanes.first else { throw RPCError.notFound("no pane") }
        let pane = try split(paneID: source.id, direction: .right, kind: .preview, focus: false,
                             file: PreviewTarget(path: file.path, format: .diff))
        return (pane, file.path)
    }

    // MARK: - Remove

    /// The worktree closing this workspace may remove: one cmds created, that no other workspace is in.
    func worktreeToRemove(onClosing workspace: Workspace) -> WorktreeRecord? {
        guard let record = workspace.createdWorktree else { return nil }
        let others = workspaces.filter { $0 !== workspace }
        return others.contains { $0.createdWorktree?.path == record.path } ? nil : record
    }

    /// Why the worktree must stay (empty: it may be removed); git runs off the main thread.
    func worktreeRemovalRefusals(_ record: WorktreeRecord) async throws -> [WorktreeRefusal] {
        try await Self.git { try Worktrees.removalRefusals(record) }
    }

    /// `workspace.close` with `removeWorktree` (and Close and Remove Worktree): checks first and keeps the workspace
    /// open when the worktree must stay; otherwise closes it and removes the worktree (`git worktree remove`, checked
    /// again). Returns the removed worktree.
    @discardableResult
    func closeWorkspaceRemovingWorktree(id: String?) async throws -> WorktreeRecord {
        let workspace = try resolveWorkspace(id)
        guard let record = worktreeToRemove(onClosing: workspace) else {
            if let created = workspace.createdWorktree { throw WorktreeError.inUse(created.path) }
            throw WorktreeError.notCreatedByCmds(workspace.worktreePath ?? workspace.workingDirectory ?? workspace.id)
        }
        let refusals = try await worktreeRemovalRefusals(record)
        guard refusals.isEmpty else { throw WorktreeError.refused(refusals) }
        if self.workspace(id: workspace.id) != nil { try closeWorkspace(id: workspace.id) }
        try await Self.git { try Worktrees.remove(record) }
        WorktreeRegistry.shared.remove(record)
        emit(.workspaces)
        return record
    }

    // MARK: - Helpers

    /// Runs blocking git work off the main thread.
    static func git<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }
}
