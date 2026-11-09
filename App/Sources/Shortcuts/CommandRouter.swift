import AppKit
import UniformTypeIdentifiers
import CmdsCore

/// Target of all app-specific menu items. Menu items have explicit targets so key equivalents work
/// regardless of which view (terminal, web view) is first responder.
@MainActor
final class CommandRouter: NSObject, NSMenuItemValidation {
    private let controller: AppController
    private weak var windowController: MainWindowController?

    /// File › Recent Agent Sessions (kept here: a menu's delegate is weak).
    let recentAgentSessions: RecentAgentSessionsMenu

    init(controller: AppController, windowController: MainWindowController) {
        self.controller = controller
        self.windowController = windowController
        recentAgentSessions = RecentAgentSessionsMenu(controller: controller)
        super.init()
        recentAgentSessions.showWindow = { [weak windowController] in windowController?.showWindow(nil) }
    }

    private var focusedBrowser: BrowserPane? { controller.focusedPane?.browser }
    private var focusedFiles: FilesPane? { controller.focusedPane?.files }

    // MARK: File

    @objc func newWorkspace(_ sender: Any?) {
        windowController?.showWindow(nil)
        controller.createWorkspace()
    }

    @objc func newSSHWorkspace(_ sender: Any?) {
        windowController?.showWindow(nil)
        SSHConnectSheet.present(in: windowController?.window, controller: controller)
    }

    /// ⌥⌘N: a workspace in a new git worktree of the selected workspace's repository (WorktreeSheet).
    @objc func newWorktreeWorkspace(_ sender: Any?) {
        windowController?.showWindow(nil)
        let selected = controller.selectedWorkspace
        WorktreeSheet.present(in: windowController?.window, controller: controller,
                              directory: selected?.isRemote == false ? selected?.workingDirectory : nil)
    }

    @objc func installRemoteHelper(_ sender: Any?) {
        guard let pane = controller.focusedPane else { return }
        RemoteHelperInstaller.confirmAndInstall(pane: pane, window: windowController?.window)
    }

    @objc func closePane(_ sender: Any?) { try? controller.closePane(id: nil) }
    @objc func closeWorkspace(_ sender: Any?) {
        // A worktree cmds created: ask whether to remove it too.
        if let workspace = controller.selectedWorkspace, controller.worktreeToRemove(onClosing: workspace) != nil {
            windowController?.sidebar.confirmClose(workspaceID: workspace.id)
            return
        }
        try? controller.closeWorkspace(id: nil)
    }

    // MARK: Find and command palette

    /// The focused pane when it is a terminal with a surface (not a disconnected SSH pane's overlay).
    private var focusedTerminalPane: Pane? {
        guard let pane = controller.focusedPane, pane.kind == .terminal, pane.terminal != nil,
              pane.container.overlay == nil else { return nil }
        return pane
    }

    /// ⌘F: the focused terminal's find bar (TerminalFind).
    @objc func find(_ sender: Any?) { focusedTerminalPane?.find.open() }
    /// ⌘G / ⇧⌘G: next (up, older output) / previous hit.
    @objc func findNext(_ sender: Any?) { focusedTerminalPane?.find.navigate(next: true) }
    @objc func findPrevious(_ sender: Any?) { focusedTerminalPane?.find.navigate(next: false) }

    /// ⇧⌘P: CommandPalette over the main window.
    @objc func showCommandPalette(_ sender: Any?) {
        windowController?.showWindow(nil)
        CommandPalette.present(controller: controller, over: windowController?.window)
    }

    // MARK: Workspace

    @objc func selectWorkspace(_ sender: NSMenuItem) { controller.selectWorkspace(at: sender.tag) }
    @objc func nextWorkspace(_ sender: Any?) { controller.selectAdjacentWorkspace(offset: 1) }
    @objc func previousWorkspace(_ sender: Any?) { controller.selectAdjacentWorkspace(offset: -1) }
    @objc func renameWorkspace(_ sender: Any?) { windowController?.sidebar.promptRename() }

    // MARK: Pane

    @objc func splitRight(_ sender: Any?) { _ = try? controller.split(direction: .right) }
    @objc func splitDown(_ sender: Any?) { _ = try? controller.split(direction: .down) }
    @objc func openBrowser(_ sender: Any?) {
        guard (try? controller.split(direction: .right, kind: .browser)) != nil else { return }
        focusedBrowser?.focusAddressBar()
    }

    /// ⇧⌘O: pick a file and show it in a preview split to the right of the focused pane.
    @objc func openInPreview(_ sender: Any?) {
        windowController?.showWindow(nil)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a file to preview")
        panel.prompt = String(localized: "Preview")
        if let directory = controller.selectedWorkspace?.workingDirectory, controller.selectedWorkspace?.isRemote == false {
            panel.directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        }
        let open: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            if self.controller.focusedPane == nil { self.controller.createWorkspace() }
            do {
                try self.controller.openFile(path: url.path)
            } catch {
                NSSound.beep()
            }
        }
        if let window = windowController?.window { panel.beginSheetModal(for: window, completionHandler: open) } else { open(panel.runModal()) }
    }

    /// ⇧⌘E: a files pane split to the right of the focused pane, in its folder (docs/guide/files.md). From an SSH pane
    /// it lists that pane's remote folder on its host.
    @objc func openFilesPane(_ sender: Any?) {
        windowController?.showWindow(nil)
        if controller.focusedPane == nil { controller.createWorkspace() }
        if let pane = controller.focusedPane, let ssh = pane.ssh {
            let folder = pane.workingDirectory ?? ssh.launch.remoteCwd ?? ""
            _ = try? controller.openFolder(paneID: pane.id, path: folder, host: ssh.launch.host)
            return
        }
        if let files = controller.focusedPane?.files, let host = files.host {
            _ = try? controller.split(direction: .right, kind: .files, cwd: files.folder, filesHost: host)
            return
        }
        _ = try? controller.split(direction: .right, kind: .files)
    }

    /// File › New Remote Files Pane…: a folder on an SSH host.
    @objc func openRemoteFilesPane(_ sender: Any?) {
        windowController?.showWindow(nil)
        RemoteFilesSheet.present(in: windowController?.window, controller: controller)
    }

    /// Window › Transfers.
    @objc func showTransfers(_ sender: Any?) {
        TransfersWindowController.shared.showWindow(nil)
    }

    // Pane › Files (the focused files pane; its list also takes the keys in docs/reference/shortcuts.md).
    @objc func filesCopyToOtherPane(_ sender: Any?) { focusedFiles?.copyToOtherPane() }
    @objc func filesMoveToOtherPane(_ sender: Any?) { focusedFiles?.moveToOtherPane() }
    @objc func filesCompare(_ sender: Any?) { focusedFiles?.compareWithOtherPane() }
    @objc func filesNewFolder(_ sender: Any?) { focusedFiles?.newFolder() }
    @objc func filesRename(_ sender: Any?) { focusedFiles?.renameSelection() }
    @objc func filesMoveToTrash(_ sender: Any?) { focusedFiles?.moveToTrash() }
    @objc func filesPreview(_ sender: Any?) { focusedFiles?.previewSelection() }
    @objc func filesEdit(_ sender: Any?) { focusedFiles?.editSelection() }
    @objc func filesStopEditing(_ sender: Any?) { focusedFiles?.stopEditing() }
    @objc func filesEnclosingFolder(_ sender: Any?) { focusedFiles?.goUp() }
    @objc func filesGoToFolder(_ sender: Any?) { focusedFiles?.goToFolder() }
    @objc func filesToggleHidden(_ sender: Any?) { focusedFiles?.toggleHiddenFiles() }
    @objc func filesToggleFollow(_ sender: Any?) { focusedFiles?.toggleFollowTerminal() }
    @objc func filesOpenTerminal(_ sender: Any?) { focusedFiles?.openTerminalHere() }

    // MARK: Export / import (AppController+Transfer.swift)

    @objc func exportWorkspaces(_ sender: Any?) {
        windowController?.showWindow(nil)
        let bundle: WorkspaceBundle
        do {
            bundle = try controller.exportBundle()
        } catch {
            return showTransferError(String(localized: "Cannot export workspaces"), error)
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "cmds-workspaces.json"
        panel.allowedContentTypes = [.json]
        panel.message = String(localized: "Workspaces and their agent sessions, to import into another cmds")
        let save: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try encoder.encode(bundle).write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                self?.showTransferError(String(localized: "Cannot export workspaces"), error)
            }
        }
        if let window = windowController?.window { panel.beginSheetModal(for: window, completionHandler: save) } else { save(panel.runModal()) }
    }

    @objc func importWorkspaces(_ sender: Any?) {
        windowController?.showWindow(nil)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = String(localized: "Choose a workspace file exported from cmds")
        panel.prompt = String(localized: "Import")
        let open: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let bundle: WorkspaceBundle
            do {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= WorkspaceBundle.maxBytes else { throw TransferError("bundle is too large (max \(WorkspaceBundle.maxBytes) bytes)") }
                bundle = try WorkspaceBundle.read(try Data(contentsOf: url))
            } catch {
                return self.showTransferError(String(localized: "Cannot import workspaces"), error)
            }
            DispatchQueue.main.async { self.confirmImport(bundle) }
        }
        if let window = windowController?.window { panel.beginSheetModal(for: window, completionHandler: open) } else { open(panel.runModal()) }
    }

    /// With workspaces open: add the imported ones after them, or replace them.
    private func confirmImport(_ bundle: WorkspaceBundle) {
        guard !controller.workspaces.isEmpty else {
            controller.importBundle(bundle)
            return
        }
        let alert = NSAlert()
        let count = bundle.workspaces.count
        let sessions = bundle.agentSessionCount
        alert.messageText = String(localized: "Import Workspaces")
        alert.informativeText = String(localized: "Workspaces: \(count), agent sessions: \(sessions). Add keeps the open workspaces; Replace closes them.")
        alert.addButton(withTitle: String(localized: "Add"))
        alert.addButton(withTitle: String(localized: "Replace"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.controller.importBundle(bundle, mode: .append)
            case .alertSecondButtonReturn: self?.controller.importBundle(bundle, mode: .replace)
            default: break
            }
        }
        if let window = windowController?.window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    private func showTransferError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = (error as? TransferError)?.message ?? (error as? RPCError)?.message ?? error.localizedDescription
        if let window = windowController?.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: Agent sessions

    @objc func resumeAgentSession(_ sender: Any?) {
        guard let pane = controller.focusedPane, controller.requestResume(pane) == nil else { return NSSound.beep() }
    }

    @objc func resumeAllAgentSessions(_ sender: Any?) {
        _ = try? controller.resumeAgentSessions(paneID: nil, all: true)
    }

    @objc func setAgentResumeMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = AgentResumeMode(rawValue: raw) else { return }
        AgentResumeSettings.mode = mode
    }

    /// View › Show Subagents (same setting as Settings › Agents).
    @objc func setSubagentDisplay(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let display = SubagentDisplay(rawValue: raw) else { return }
        AppSettings.shared.showSubagents = display
    }

    @objc func focusLeft(_ sender: Any?) { windowController?.focusNeighbor(.left) }
    @objc func focusRight(_ sender: Any?) { windowController?.focusNeighbor(.right) }
    @objc func focusUp(_ sender: Any?) { windowController?.focusNeighbor(.up) }
    @objc func focusDown(_ sender: Any?) { windowController?.focusNeighbor(.down) }
    /// ⇧⌘↩: zooms the active tile in the tiled view, else the focused pane.
    @objc func toggleZoom(_ sender: Any?) {
        if controller.isTiling { controller.toggleTileZoom() } else { try? controller.toggleZoom() }
    }
    @objc func toggleTileAll(_ sender: Any?) { controller.toggleTileAll() }
    @objc func tileSelected(_ sender: Any?) { controller.restoreTileSelection() }
    @objc func showSingleWorkspace(_ sender: Any?) { try? controller.setTiling(.off) }
    @objc func jumpToAttention(_ sender: Any?) { controller.jumpToLatestAttention() }
    /// ⌃⇧⌘ + arrow: moves the active tile (beeps at the edge).
    @objc func moveTileLeft(_ sender: Any?) { moveTile(.left) }
    @objc func moveTileRight(_ sender: Any?) { moveTile(.right) }
    @objc func moveTileUp(_ sender: Any?) { moveTile(.up) }
    @objc func moveTileDown(_ sender: Any?) { moveTile(.down) }
    private func moveTile(_ direction: TileArrangement.Direction) {
        if !controller.moveActiveTile(direction) { NSSound.beep() }
    }

    // MARK: Browser

    @objc func browserFocusAddress(_ sender: Any?) { focusedBrowser?.focusAddressBar() }
    /// ⌘R: reload the focused browser, preview or files pane, or reconnect the focused SSH pane whose ssh is not running.
    @objc func browserReload(_ sender: Any?) {
        if let pane = controller.focusedDisconnectedSSHPane {
            try? controller.connectSSH(paneID: pane.id)
        } else if let preview = controller.focusedPane?.preview {
            preview.reload()
        } else if let files = focusedFiles {
            files.reload()
        } else {
            focusedBrowser?.reload()
        }
    }
    /// ⌘[ / ⌘]: the focused browser's or files pane's history.
    @objc func browserBack(_ sender: Any?) {
        if let files = focusedFiles { files.goBack() } else { focusedBrowser?.goBack() }
    }
    @objc func browserForward(_ sender: Any?) {
        if let files = focusedFiles { files.goForward() } else { focusedBrowser?.goForward() }
    }

    // MARK: View / Help

    @objc func toggleSidebar(_ sender: Any?) { windowController?.toggleSidebar() }
    @objc func toggleCompactSidebar(_ sender: Any?) { windowController?.toggleCompactSidebar() }
    @objc func filterWorkspaces(_ sender: Any?) { windowController?.showSidebarFilter() }
    @objc func toggleWorkspaceUsage(_ sender: Any?) {
        SidebarPreferences.showsWorkspaceUsage.toggle()
        windowController?.sidebar.reload()
    }
    @objc func toggleGroupByProject(_ sender: Any?) {
        guard let sidebar = windowController?.sidebar else { return }
        sidebar.setGroupsByProject(!sidebar.groupsByProject)
    }

    @objc func showShortcuts(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Keyboard Shortcuts")
        alert.informativeText = String(localized: """
            New workspace ⌘N · Close pane ⌘W · Close workspace ⇧⌘W
            Workspace 1–9 ⌘1…⌘9 · Next/previous ⌃Tab / ⌃⇧Tab, ⇧⌘] / ⇧⌘[
            Split right ⌘D · Split down ⇧⌘D · Zoom pane ⇧⌘↩
            Focus pane ⌥⌘←/→/↑/↓ · Latest attention ⇧⌘U
            Browser split ⇧⌘B · Address ⌘L · Reload ⌘R · Back ⌘[ · Forward ⌘]
            Open in Preview ⇧⌘O · ⌘-click a file path in a terminal to preview it
            New Files Pane ⇧⌘E · in the list: Return open · Space preview · F5/F6 copy/move to the other pane · F2 rename · F7 new folder · ⌘⌫ Trash · ⌘↑ up · ⇧⌘. hidden files
            Toggle sidebar ⌘B · Rename workspace ⇧⌘R
            Tile workspaces: ⌘-click / ⇧-click in the sidebar · Tile all ⌃⌘T · Zoom tile ⇧⌘↩
            """)
        if let window = windowController?.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: Debug

    #if DEBUG
    /// Lights a pane that is not focused (or the focused one when it is alone), to exercise the ring.
    @objc func debugNotifyOtherPane(_ sender: Any?) {
        let panes = controller.workspaces.flatMap(\.orderedPanes)
        let target = panes.first { $0.id != controller.focusedPane?.id } ?? controller.focusedPane
        guard let target else { return }
        try? controller.notify(paneID: target.id, title: "Debug", body: "Agent is waiting for input in \(target.id)")
    }

    /// Notifies the focused pane after 3 s, so it can be tested with the app in the background.
    @objc func debugNotifyFocusedPaneLater(_ sender: Any?) {
        guard let id = controller.focusedPane?.id else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                try? self?.controller.notify(paneID: id, title: "Debug", body: "Delayed notification for \(id)")
            }
        }
    }

    @objc func debugSetStatus(_ sender: Any?) {
        try? controller.setStatus(workspaceID: nil, text: "Status set at \(Date().formatted(date: .omitted, time: .standard))")
    }
    #endif

    // MARK: Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(find(_:)):
            return focusedTerminalPane != nil
        case #selector(findNext(_:)), #selector(findPrevious(_:)):
            return focusedTerminalPane?.find.isOpen == true
        case #selector(browserReload(_:)):
            if controller.focusedDisconnectedSSHPane != nil {
                menuItem.title = String(localized: "Reconnect SSH")
                return true
            }
            if controller.focusedPane?.preview != nil {
                menuItem.title = String(localized: "Reload Preview")
                return true
            }
            if focusedFiles != nil {
                menuItem.title = String(localized: "Reload Folder")
                return true
            }
            menuItem.title = String(localized: "Reload Page")
            return focusedBrowser != nil
        case #selector(resumeAgentSession(_:)):
            return controller.focusedPane?.resumeOffer != nil
        case #selector(resumeAllAgentSessions(_:)):
            return controller.pendingResumeCount > 0
        case #selector(setAgentResumeMode(_:)):
            menuItem.state = (menuItem.representedObject as? String) == AgentResumeSettings.mode.rawValue ? .on : .off
            return true
        case #selector(setSubagentDisplay(_:)):
            menuItem.state = (menuItem.representedObject as? String) == AppSettings.shared.showSubagents.rawValue ? .on : .off
            return true
        case #selector(installRemoteHelper(_:)):
            return controller.focusedPane?.ssh?.connected == true
        case #selector(browserBack(_:)):
            if let files = focusedFiles { return !files.backStack.isEmpty }
            return focusedBrowser != nil
        case #selector(browserForward(_:)):
            if let files = focusedFiles { return !files.forwardStack.isEmpty }
            return focusedBrowser != nil
        case #selector(browserFocusAddress(_:)):
            return focusedBrowser != nil
        case #selector(filesToggleHidden(_:)):
            menuItem.state = focusedFiles?.showHidden == true ? .on : .off
            return focusedFiles != nil
        case #selector(filesToggleFollow(_:)):
            menuItem.state = focusedFiles?.followsTerminal == true ? .on : .off
            return focusedFiles != nil
        case #selector(filesCopyToOtherPane(_:)), #selector(filesMoveToOtherPane(_:)),
             #selector(filesMoveToTrash(_:)), #selector(filesPreview(_:)):
            return focusedFiles?.selectedEntries.isEmpty == false
        case #selector(filesCompare(_:)):
            return focusedFiles?.otherPane?() != nil
        case #selector(filesEdit(_:)):
            return focusedFiles?.selectedEntries.contains { !$0.isFolder } == true
        case #selector(filesStopEditing(_:)):
            guard let files = focusedFiles else { return false }
            return !files.editSessions(for: files.selectedEntries).isEmpty
        case #selector(filesRename(_:)):
            // One row, like Rename in the list's context menu.
            return focusedFiles?.selectedEntries.count == 1
        case #selector(filesNewFolder(_:)), #selector(filesEnclosingFolder(_:)), #selector(filesGoToFolder(_:)),
             #selector(filesOpenTerminal(_:)):
            return focusedFiles != nil
        case #selector(closePane(_:)), #selector(closeWorkspace(_:)), #selector(splitRight(_:)),
             #selector(splitDown(_:)), #selector(openBrowser(_:)), #selector(renameWorkspace(_:)),
             #selector(focusLeft(_:)), #selector(focusRight(_:)), #selector(focusUp(_:)), #selector(focusDown(_:)):
            return controller.focusedPane != nil
        case #selector(toggleCompactSidebar(_:)):
            menuItem.state = windowController?.sidebar.isCompact == true ? .on : .off
            return true
        case #selector(toggleWorkspaceUsage(_:)):
            menuItem.state = SidebarPreferences.showsWorkspaceUsage ? .on : .off
            return true
        case #selector(toggleGroupByProject(_:)):
            menuItem.state = windowController?.sidebar.groupsByProject == true ? .on : .off
            return true
        case #selector(toggleZoom(_:)):
            if controller.isTiling {
                menuItem.title = String(localized: "Zoom Tile")
                menuItem.state = controller.tileZoomedWorkspaceID != nil ? .on : .off
                return true
            }
            menuItem.title = String(localized: "Zoom Pane")
            menuItem.state = controller.selectedWorkspace?.zoomedPaneID != nil ? .on : .off
            return (controller.selectedWorkspace?.panes.count ?? 0) > 1
        case #selector(toggleTileAll(_:)):
            menuItem.state = controller.isTiling && controller.tileMode == .all ? .on : .off
            return controller.isTiling || controller.workspaces.count >= 2
        case #selector(tileSelected(_:)):
            return controller.canRestoreTileSelection
        case #selector(showSingleWorkspace(_:)):
            return controller.isTiling
        case #selector(moveTileLeft(_:)), #selector(moveTileRight(_:)), #selector(moveTileUp(_:)),
             #selector(moveTileDown(_:)):
            return controller.canMoveActiveTile
        case #selector(selectWorkspace(_:)):
            return controller.workspaces.indices.contains(menuItem.tag)
        case #selector(jumpToAttention(_:)):
            return controller.attentionCount > 0
        default:
            return true
        }
    }
}
