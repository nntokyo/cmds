import AppKit
import CmdsCore

/// "New Worktree Workspace…" (File menu, a workspace's sidebar menu): repository folder, new branch, base, location
/// and an optional command; the same as `cmds new --worktree` (AppController+Worktrees.swift).
@MainActor
enum WorktreeSheet {
    static func present(in window: NSWindow?, controller: AppController, directory: String?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "New Worktree Workspace")
        alert.informativeText = String(localized: "Fetches, creates a new branch from the base and a git worktree for it, and opens a workspace there, so agents can work side by side without touching your checkout.")
        alert.addButton(withTitle: String(localized: "Create"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let repository = NSTextField()
        repository.placeholderString = String(localized: "a folder in the repository")
        repository.stringValue = (directory.flatMap(GitInfo.projectRoot(at:)) ?? directory ?? "").abbreviatingHome
        let branch = NSTextField()
        branch.placeholderString = String(localized: "new branch, e.g. fix-login")
        let base = NSTextField()
        base.placeholderString = String(localized: "default branch (e.g. origin/main)")
        let location = NSTextField()
        location.placeholderString = String(localized: "<repository>-worktrees/<branch> next to it")
        let command = NSTextField()
        command.placeholderString = String(localized: "command (optional, e.g. claude)")

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "Repository:")), repository],
            [NSTextField(labelWithString: String(localized: "Branch:")), branch],
            [NSTextField(labelWithString: String(localized: "Base:")), base],
            [NSTextField(labelWithString: String(localized: "Location:")), location],
            [NSTextField(labelWithString: String(localized: "Command:")), command],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        for field in [repository, branch, base, location, command] {
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        grid.frame = NSRect(x: 0, y: 0, width: 400, height: 144)
        alert.accessoryView = grid
        alert.window.initialFirstResponder = repository.stringValue.isEmpty ? repository : branch

        func value(_ field: NSTextField) -> String? {
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : (text as NSString).expandingTildeInPath
        }
        present(alert, in: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let request = Worktrees.Request(branch: branch.stringValue, base: value(base), path: value(location))
            let folder = value(repository) ?? ""
            let program = command.stringValue.trimmingCharacters(in: .whitespaces)
            Task { @MainActor in
                do {
                    let created = try await controller.createWorktreeWorkspace(
                        from: folder, request: request, command: program.isEmpty ? nil : program)
                    if let warning = created.warning {
                        inform(String(localized: "The worktree starts from what was fetched before"), warning, in: window)
                    }
                } catch {
                    inform(String(localized: "Cannot create the worktree"), worktreeErrorText(error), in: window)
                }
            }
        }
    }

    /// As a sheet on `window`, or app-modal without one.
    static func present(_ alert: NSAlert, in window: NSWindow?, then handle: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.attachedSheet == nil { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    static func inform(_ message: String, _ text: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = text
        present(alert, in: window) { _ in }
    }
}

/// Closing a workspace whose worktree cmds created (sidebar ×, its menu, File › Close Workspace): Close Workspace keeps
/// the worktree; Close and Remove Worktree removes it after the checks (AppController+Worktrees.swift).
@MainActor
enum WorktreeCloseAlert {
    /// The alert's text and buttons (also `debug.close_alert`).
    static func make(workspace: Workspace, record: WorktreeRecord) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "Close “\(workspace.displayTitle)”?")
        var text = String(localized: "cmds created the worktree \(record.path.abbreviatingHome) (branch \(record.branch)) for this workspace. Close and Remove Worktree also removes that folder with git worktree remove: files git ignores (build output, dependencies) go with it, the branch stays. It is not removed while it has uncommitted changes, untracked files or commits that are not pushed.")
        if workspace.agentActivity != .none {
            text += "\n\n" + String(localized: "A coding agent is running in this workspace. Closing it ends the agent and its terminals.")
        }
        alert.informativeText = text
        alert.addButton(withTitle: String(localized: "Close Workspace"))
        alert.addButton(withTitle: String(localized: "Close and Remove Worktree"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert
    }

    static func present(workspace: Workspace, record: WorktreeRecord, in window: NSWindow?, controller: AppController) {
        let id = workspace.id
        WorktreeSheet.present(make(workspace: workspace, record: record), in: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                try? controller.closeWorkspace(id: id)
            case .alertSecondButtonReturn:
                Task { @MainActor in
                    do {
                        try await controller.closeWorkspaceRemovingWorktree(id: id)
                    } catch WorktreeError.refused(let refusals) {
                        let reasons = refusals.map { "• " + $0.localizedText }.joined(separator: "\n")
                        WorktreeSheet.inform(String(localized: "The worktree was kept"),
                                             reasons + "\n\n" + String(localized: "Commit and push the work first, or close the workspace and keep the worktree."),
                                             in: window)
                    } catch {
                        WorktreeSheet.inform(String(localized: "Cannot remove the worktree"), worktreeErrorText(error), in: window)
                    }
                }
            default:
                break
            }
        }
    }
}

/// Show Changes (a workspace's sidebar menu): the diff preview, or an alert when git cannot compare.
@MainActor
enum ShowChangesAction {
    static func run(workspaceID: String, controller: AppController, window: NSWindow?) {
        Task { @MainActor in
            do {
                try await controller.showChanges(workspaceID: workspaceID)
            } catch {
                WorktreeSheet.inform(String(localized: "Cannot show the changes"), worktreeErrorText(error), in: window)
            }
        }
    }
}
