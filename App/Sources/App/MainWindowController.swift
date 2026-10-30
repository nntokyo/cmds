import AppKit
import CmdsCore
import Combine

/// The single main window: sidebar (vertical tabs) + selected workspace's split tree.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let controller: AppController
    let sidebar: SidebarViewController
    let content: WorkspaceContentViewController
    private let splitViewController = NSSplitViewController()
    private let sidebarItem: NSSplitViewItem
    /// Sidebar width before switching to the compact rail, restored when leaving it.
    private var expandedSidebarWidth: CGFloat = 220
    private var subscription: AnyCancellable?
    private var usageSubscription: AnyCancellable?
    private var mouseMonitor: Any?

    init(controller: AppController) {
        self.controller = controller
        sidebar = SidebarViewController(controller: controller)
        content = WorkspaceContentViewController(controller: controller)

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = Self.sidebarMinimum
        sidebarItem.maximumThickness = Self.sidebarMaximum
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 300
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentItem)
        // Isolated test instances (CMDS_SUPPORT_DIR) share the defaults domain: keep the user's layout.
        let isolated = CmdsEnv.supportDirectoryOverride() != nil
        if !isolated { splitViewController.splitView.autosaveName = "cmds.sidebar" }

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
        if !isolated { window.setFrameAutosaveName("cmds.main") }
        super.init(window: window)
        window.delegate = self
        controller.window = window

        subscription = controller.changes.sink { [weak self] _ in self?.refresh() }
        // Usage samples only touch the usage labels and the footer, never a full sidebar reload.
        usageSubscription = controller.usageChanges.sink { [weak self] in self?.sidebar.updateUsage() }
        installMouseMonitor()
        sidebar.onToggleCompact = { [weak self] in self?.toggleCompactSidebar() }
        // The tiled view follows the sidebar's order and filter.
        controller.visibleWorkspaceOrder = { [weak self] in self?.sidebar.visibleWorkspaceIDs ?? [] }
        sidebar.onRowsChanged = { [weak self] in self?.controller.tileSourceDidChange() }
        refresh()
        if Self.storedCompact { setCompactSidebar(true, persist: false) }
    }

    static let sidebarMinimum: CGFloat = 180
    static let sidebarMaximum: CGFloat = 420
    static let compactDefaultsKey = "SidebarCompact"
    static let expandedWidthDefaultsKey = "SidebarExpandedWidth"

    /// Isolated test instances share the defaults domain with the app in use: they neither read nor write the setting
    /// and start compact only with `CMDS_SIDEBAR_COMPACT=1`.
    private static var storedCompact: Bool {
        if CmdsEnv.supportDirectoryOverride() != nil {
            return ProcessInfo.processInfo.environment["CMDS_SIDEBAR_COMPACT"] == "1"
        }
        return UserDefaults.standard.bool(forKey: compactDefaultsKey)
    }

    func toggleCompactSidebar() {
        setCompactSidebar(!sidebar.isCompact, persist: true)
    }

    /// Compact: a fixed `SidebarViewController.compactWidth` rail (workspace numbers, attention, status colour).
    func setCompactSidebar(_ compact: Bool, persist: Bool) {
        guard compact != sidebar.isCompact else { return }
        if sidebarItem.isCollapsed { sidebarItem.animator().isCollapsed = false }
        let isolated = CmdsEnv.supportDirectoryOverride() != nil
        if compact {
            // At launch (`persist == false`) the frame is not restored yet: use the width saved when compacting.
            let width = persist ? sidebar.view.frame.width : 0
            if width >= Self.sidebarMinimum {
                expandedSidebarWidth = width
                if !isolated { UserDefaults.standard.set(Double(width), forKey: Self.expandedWidthDefaultsKey) }
            } else if !isolated, UserDefaults.standard.double(forKey: Self.expandedWidthDefaultsKey) >= Self.sidebarMinimum {
                // Launched compact: the autosaved divider is the rail; use the width saved when compacting.
                expandedSidebarWidth = UserDefaults.standard.double(forKey: Self.expandedWidthDefaultsKey)
            }
            sidebar.isCompact = true
            sidebarItem.minimumThickness = SidebarViewController.compactWidth
            sidebarItem.maximumThickness = SidebarViewController.compactWidth
            splitViewController.splitView.setPosition(SidebarViewController.compactWidth, ofDividerAt: 0)
        } else {
            sidebar.isCompact = false
            // Raise the maximum first so min never exceeds max.
            sidebarItem.maximumThickness = Self.sidebarMaximum
            sidebarItem.minimumThickness = Self.sidebarMinimum
            splitViewController.splitView.setPosition(expandedSidebarWidth, ofDividerAt: 0)
        }
        if persist, !isolated {
            UserDefaults.standard.set(compact, forKey: Self.compactDefaultsKey)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        sidebar.reload()
        content.render()
        if let workspace = controller.selectedWorkspace {
            window?.title = workspace.displayTitle
            // An agent's title without its spinner glyph (glyph-only title changes are not emitted).
            window?.subtitle = workspace.focusedPane.map { $0.agentTopic ?? DefaultTitle.localized($0.title) } ?? ""
        } else {
            window?.title = "cmds"
            window?.subtitle = ""
        }
    }

    func toggleSidebar() {
        splitViewController.toggleSidebar(nil)
    }

    /// ⌥⌘F: shows the sidebar (expanded) with its filter field focused.
    func showSidebarFilter() {
        if sidebarItem.isCollapsed { sidebarItem.isCollapsed = false }
        sidebar.beginFilter()
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
