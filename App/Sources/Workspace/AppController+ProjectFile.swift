import AppKit
import CmdsCore

/// `.cmds.json` (#174 G20, `ProjectFile`): Workspace › Run Project Commands, `project.show` / `project.run`. A file
/// is confirmed by the user in the app (its digest is remembered per path); a new or changed one is shown in full
/// first. The API and CLI run only a confirmed file, so a script or an agent cannot run commands nobody saw.
extension AppController {
    /// The project file of `workspace`'s local folder (its focused terminal's, else the workspace's): its path and
    /// contents. Throws when there is none or it is invalid.
    func projectFile(workspace: Workspace) throws -> (path: String, file: ProjectFile) {
        guard !workspace.isRemote, let folder = workspace.focusedPane?.workingDirectory ?? workspace.workingDirectory else {
            throw RPCError.notFound("the workspace has no local folder")
        }
        guard let path = ProjectFile.find(from: folder) else {
            throw RPCError.notFound("no \(ProjectFile.fileName) in \(folder) or its parents up to the repository")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        do {
            return (path, try ProjectFile.parse(data))
        } catch let error as ProjectFile.Invalid {
            throw RPCError.invalidParams("\(path): \(error.description)")
        }
    }

    func isConfirmed(_ file: ProjectFile, at path: String) -> Bool {
        AppSettings.shared.confirmedProjectFiles[path] == file.digest
    }

    /// `project.show`: `{path, lines, confirmed}`.
    func projectShow(workspaceID: String?) throws -> JSONValue {
        let (path, file) = try projectFile(workspace: try resolveWorkspace(workspaceID))
        return .object(["path": .string(path), "lines": .array(file.lines.map(JSONValue.string)),
                        "confirmed": .bool(isConfirmed(file, at: path))])
    }

    /// `project.run`: runs a confirmed file (403 otherwise: Workspace › Run Project Commands shows it first).
    func projectRun(workspaceID: String?) throws -> JSONValue {
        let workspace = try resolveWorkspace(workspaceID)
        let (path, file) = try projectFile(workspace: workspace)
        guard isConfirmed(file, at: path) else {
            throw RPCError(code: 403, message: "\(path) is new or changed since it was confirmed: run Workspace › Run Project Commands in cmds to see and confirm it")
        }
        return try runProject(file, at: path, in: workspace)
    }

    /// Opens a terminal per command (in the project folder; the shell stays when the command ends), each split from
    /// the one before (the first from the focused pane), then the pages in a browser beside them. Returns the panes.
    @discardableResult
    func runProject(_ file: ProjectFile, at path: String, in workspace: Workspace) throws -> JSONValue {
        guard let source = workspace.focusedPane ?? workspace.orderedPanes.first else { throw RPCError.notFound("no pane") }
        let folder = (path as NSString).deletingLastPathComponent
        var previous = source.id
        var opened: [JSONValue] = []
        for command in file.commands {
            let line = "\(command.run); exec \"${SHELL:-/bin/zsh}\" -l"
            let info = try split(paneID: previous, direction: command.split == .down ? .down : .right, kind: .terminal,
                                 cwd: folder, command: line, focus: false, asTab: command.split == .tab)
            pane(id: info.id)?.title = command.title
            previous = info.id
            opened.append(.object(["pane": .string(info.id), "title": .string(command.title)]))
        }
        for page in file.pages {
            let info = try openBrowser(paneID: previous, url: page, focus: false)
            opened.append(.object(["pane": .string(info.id), "url": .string(page)]))
        }
        emit(.workspace(id: workspace.id))
        return .object(["path": .string(path), "opened": .array(opened)])
    }

    /// Workspace › Run Project Commands: runs a confirmed file; shows a new or changed one in full first and runs it
    /// (remembering it) when the user confirms.
    func runProjectCommandsFromMenu() {
        guard let workspace = selectedWorkspace else { return NSSound.beep() }
        let found: (path: String, file: ProjectFile)
        do {
            found = try projectFile(workspace: workspace)
        } catch let error as RPCError {
            let alert = NSAlert()
            alert.messageText = String(localized: "No project commands", comment: "alert title: no .cmds.json found or it is invalid")
            alert.informativeText = error.message + "\n\n"
                + String(localized: "Put a .cmds.json in the project with the commands to run and the pages to open, for example:",
                         comment: "alert text when no .cmds.json is found; a JSON example follows")
                + "\n\n{\"commands\": [{\"title\": \"Dev server\", \"run\": \"npm run dev\"}],\n \"open\": [\"http://localhost:5173\"]}"
            alert.alertStyle = .informational
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        } catch {
            return NSSound.beep()
        }
        if isConfirmed(found.file, at: found.path) {
            _ = try? runProject(found.file, at: found.path, in: workspace)
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Run the commands of this project?", comment: "alert title before running a .cmds.json the first time")
        alert.informativeText = String(localized: "\(found.path) asks to run these in new terminals. Run them only if you trust this project.",
                                       comment: "alert text before running a .cmds.json; argument: its path")
            + "\n\n" + found.file.lines.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Run", comment: "button: run the project's commands"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            AppSettings.shared.confirmedProjectFiles[found.path] = found.file.digest
            _ = try? self.runProject(found.file, at: found.path, in: workspace)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }
}
