import AppKit
import UniformTypeIdentifiers
import CmdsCore

/// Target of all app-specific menu items. Menu items have explicit targets so key equivalents work
/// regardless of which view (terminal, web view) is first responder.
@MainActor
final class CommandRouter: NSObject, NSMenuItemValidation {
    private let controller: AppController
    private weak var windowController: MainWindowController?

    init(controller: AppController, windowController: MainWindowController) {
        self.controller = controller
        self.windowController = windowController
    }

    private var focusedBrowser: BrowserPane? { controller.focusedPane?.browser }

    // MARK: File

    @objc func newWorkspace(_ sender: Any?) {
        windowController?.showWindow(nil)
        controller.createWorkspace()
    }

    @objc func newSSHWorkspace(_ sender: Any?) {
        windowController?.showWindow(nil)
        SSHConnectSheet.present(in: windowController?.window, controller: controller)
    }

    @objc func installRemoteHelper(_ sender: Any?) {
        guard let pane = controller.focusedPane else { return }
        RemoteHelperInstaller.confirmAndInstall(pane: pane, window: windowController?.window)
    }

    @objc func closePane(_ sender: Any?) { try? controller.closePane(id: nil) }
    @objc func closeWorkspace(_ sender: Any?) { try? controller.closeWorkspace(id: nil) }

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
    /// ⌘R: reload the focused browser or preview, or reconnect the focused SSH pane whose ssh is not running.
    @objc func browserReload(_ sender: Any?) {
        if let pane = controller.focusedDisconnectedSSHPane {
            try? controller.connectSSH(paneID: pane.id)
        } else if let preview = controller.focusedPane?.preview {
            preview.reload()
        } else {
            focusedBrowser?.reload()
        }
    }
    @objc func browserBack(_ sender: Any?) { focusedBrowser?.goBack() }
    @objc func browserForward(_ sender: Any?) { focusedBrowser?.goForward() }

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
            Toggle sidebar ⌘B · Rename workspace ⇧⌘R
            Tile workspaces: ⌘-click / ⇧-click in the sidebar · Tile all ⌃⌘T · Zoom tile ⇧⌘↩
            """)
        if let window = windowController?.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: Debug

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

    // MARK: Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(browserReload(_:)):
            if controller.focusedDisconnectedSSHPane != nil {
                menuItem.title = String(localized: "Reconnect SSH")
                return true
            }
            if controller.focusedPane?.preview != nil {
                menuItem.title = String(localized: "Reload Preview")
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
        case #selector(installRemoteHelper(_:)):
            return controller.focusedPane?.ssh?.connected == true
        case #selector(browserFocusAddress(_:)),
             #selector(browserBack(_:)), #selector(browserForward(_:)):
            return focusedBrowser != nil
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
