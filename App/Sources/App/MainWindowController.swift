import AppKit
import Combine

/// The single main window: sidebar (vertical tabs) + selected workspace's split tree.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let controller: AppController
    let sidebar: SidebarViewController
    let content: WorkspaceContentViewController
    private let splitViewController = NSSplitViewController()
    private var subscription: AnyCancellable?
    private var mouseMonitor: Any?

    init(controller: AppController) {
        self.controller = controller
        sidebar = SidebarViewController(controller: controller)
        content = WorkspaceContentViewController(controller: controller)

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 300
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentItem)
        splitViewController.splitView.autosaveName = "cmds.sidebar"

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "cmds"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1)
        window.contentViewController = splitViewController
        window.minSize = NSSize(width: 640, height: 400)
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.center()
        window.setFrameAutosaveName("cmds.main")
        super.init(window: window)
        window.delegate = self
        controller.window = window

        subscription = controller.changes.sink { [weak self] _ in self?.refresh() }
        installMouseMonitor()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        sidebar.reload()
        content.render()
        if let workspace = controller.selectedWorkspace {
            window?.title = workspace.title
            window?.subtitle = workspace.focusedPane?.title ?? ""
        } else {
            window?.title = "cmds"
            window?.subtitle = ""
        }
    }

    func toggleSidebar() {
        splitViewController.toggleSidebar(nil)
    }

    func focusNeighbor(_ direction: FocusDirection) {
        guard let current = controller.focusedPane,
              let target = content.neighbor(of: current.id, direction: direction) else { return }
        try? controller.focusPane(id: target)
    }

    /// Clicking anywhere inside a pane focuses it (covers browser panes and engine views alike).
    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self.window,
                  let id = self.content.paneID(atWindowPoint: event.locationInWindow),
                  let pane = self.controller.pane(id: id) else { return event }
            self.controller.paneDidBecomeFocused(pane)
            return event
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        controller.windowDidBecomeKey()
    }
}
