import AppKit

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

    @objc func focusLeft(_ sender: Any?) { windowController?.focusNeighbor(.left) }
    @objc func focusRight(_ sender: Any?) { windowController?.focusNeighbor(.right) }
    @objc func focusUp(_ sender: Any?) { windowController?.focusNeighbor(.up) }
    @objc func focusDown(_ sender: Any?) { windowController?.focusNeighbor(.down) }
    @objc func toggleZoom(_ sender: Any?) { try? controller.toggleZoom() }
    @objc func jumpToAttention(_ sender: Any?) { controller.jumpToLatestAttention() }

    // MARK: Browser

    @objc func browserFocusAddress(_ sender: Any?) { focusedBrowser?.focusAddressBar() }
    /// ⌘R: reload the focused browser, or reconnect the focused SSH pane whose ssh is not running.
    @objc func browserReload(_ sender: Any?) {
        if let pane = controller.focusedDisconnectedSSHPane {
            try? controller.connectSSH(paneID: pane.id)
        } else {
            focusedBrowser?.reload()
        }
    }
    @objc func browserBack(_ sender: Any?) { focusedBrowser?.goBack() }
    @objc func browserForward(_ sender: Any?) { focusedBrowser?.goForward() }

    // MARK: View / Help

    @objc func toggleSidebar(_ sender: Any?) { windowController?.toggleSidebar() }
    @objc func toggleCompactSidebar(_ sender: Any?) { windowController?.toggleCompactSidebar() }

    @objc func showShortcuts(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Keyboard Shortcuts"
        alert.informativeText = """
            New workspace ⌘N · Close pane ⌘W · Close workspace ⇧⌘W
            Workspace 1–9 ⌘1…⌘9 · Next/previous ⌃Tab / ⌃⇧Tab, ⇧⌘] / ⇧⌘[
            Split right ⌘D · Split down ⇧⌘D · Zoom pane ⇧⌘↩
            Focus pane ⌥⌘←/→/↑/↓ · Latest attention ⇧⌘U
            Browser split ⇧⌘B · Address ⌘L · Reload ⌘R · Back ⌘[ · Forward ⌘]
            Toggle sidebar ⌘B · Rename workspace ⇧⌘R
            """
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
                menuItem.title = "Reconnect SSH"
                return true
            }
            menuItem.title = "Reload Page"
            return focusedBrowser != nil
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
        case #selector(toggleZoom(_:)):
            menuItem.state = controller.selectedWorkspace?.zoomedPaneID != nil ? .on : .off
            return (controller.selectedWorkspace?.panes.count ?? 0) > 1
        case #selector(selectWorkspace(_:)):
            return controller.workspaces.indices.contains(menuItem.tag)
        case #selector(jumpToAttention(_:)):
            return controller.attentionCount > 0
        default:
            return true
        }
    }
}
