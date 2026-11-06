import AppKit
import Combine
import CmdsCore

/// The menu bar item (#95), drawn rather than written: the cmds glyph with an orange badge (workspaces that need the
/// user, orange in the sidebar) and an accent badge circled by a turning arc while agents work. Its menu shows ring
/// charts for CPU, memory and the agents' account limits, then every workspace with an agent and a mark for what it
/// is doing; choosing one brings cmds forward on it. Settings › Agents › Show in menu bar.
@MainActor
final class MenuBarStatusItem: NSObject, NSMenuDelegate {
    private let controller: AppController
    private let showWorkspace: (String?) -> Void
    private var item: NSStatusItem?
    private var subscription: AnyCancellable?
    private var usageSubscription: AnyCancellable?
    private let dashboard = MenuBarDashboardView()
    private lazy var dashboardItem: NSMenuItem = {
        let item = NSMenuItem()
        item.view = dashboard
        return item
    }()
    private var menuIsOpen = false
    private var appliedCounts: Counts?
    /// Turns the spinners (status bar badge, working workspaces in the open menu) while agents work.
    private var spinner: Timer?
    private var phase = 0.0
    private var workingMenuItems: [NSMenuItem] = []

    private struct Counts: Equatable {
        var needingUser: Int
        var working: Int
    }

    /// One spinner turn takes this long, in `steps` frames.
    private static let turn: TimeInterval = 1.2
    private static let steps = 12

    /// `showWorkspace` brings the main window forward, on a workspace if one is given.
    init(controller: AppController, showWorkspace: @escaping (String?) -> Void) {
        self.controller = controller
        self.showWorkspace = showWorkspace
        super.init()
    }

    func start() {
        subscription = controller.changes.sink { [weak self] _ in self?.update() }
        usageSubscription = controller.usageChanges.sink { [weak self] in
            guard let self, self.menuIsOpen else { return }
            self.updateDashboard()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: AppSettings.didChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(motionPreferenceChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                          object: nil)
        settingsChanged()
    }

    @objc private func settingsChanged() {
        if AppSettings.shared.showInMenuBar {
            guard item == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
            appliedCounts = nil
            update()
        } else if let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
            updateSpinner(working: false)
        }
    }

    @objc private func motionPreferenceChanged() {
        appliedCounts = nil
        update()
    }

    private var summary: MenuBarSummary {
        MenuBarSummary(controller.workspaces.map { workspace in
            MenuBarSummary.Entry(id: workspace.id, title: workspace.displayTitle,
                                 needsUser: AgentActivityStyle.needsUser(workspace),
                                 working: AgentActivityStyle.isWorking(workspace))
        })
    }

    private func update() {
        guard let button = item?.button else { return }
        let summary = summary
        let counts = Counts(needingUser: summary.needingUser.count, working: summary.working.count)
        updateSpinner(working: counts.working > 0)
        guard counts != appliedCounts else { return }
        appliedCounts = counts
        drawStatusImage()
        let description = Self.description(counts)
        button.setAccessibilityLabel(description)
        button.toolTip = description
    }

    private func drawStatusImage() {
        guard let button = item?.button, let counts = appliedCounts else { return }
        button.image = MenuBarIcon.statusImage(needingUser: counts.needingUser, working: counts.working, phase: phase)
    }

    /// Runs the spinner timer while agents work, unless the user asked for reduced motion (then the arc stands still).
    private func updateSpinner(working: Bool) {
        let animate = working && item != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate, spinner == nil {
            let timer = Timer(timeInterval: Self.turn / Double(Self.steps), repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.advanceSpinner() }
            }
            RunLoop.main.add(timer, forMode: .common)  // also while the menu is open
            spinner = timer
        } else if !animate, let timer = spinner {
            timer.invalidate()
            spinner = nil
        }
    }

    private func advanceSpinner() {
        phase = (phase + 1 / Double(Self.steps)).truncatingRemainder(dividingBy: 1)
        drawStatusImage()
        for item in workingMenuItems { item.image = MenuBarIcon.stateImage(.working, phase: phase) }
    }

    /// Tooltip and VoiceOver label.
    private static func description(_ counts: Counts) -> String {
        guard counts.needingUser > 0 || counts.working > 0 else { return "cmds" }
        return "cmds — " + String(localized: "\(counts.needingUser) need you, \(counts.working) working",
                                  comment: "menu bar item: workspaces waiting for the user, and with an agent working")
    }

    // MARK: Menu

    private func updateDashboard() {
        dashboard.update(sample: controller.systemSample, agentLimits: controller.activeAgentLimits())
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        workingMenuItems = []
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        updateDashboard()
        menu.addItem(dashboardItem)
        menu.addItem(.separator())
        workingMenuItems = []
        let agents = Self.agentWorkspaces(controller.workspaces)
        for (workspace, state) in agents {
            let item = workspaceItem(workspace, state: state)
            if state == .working { workingMenuItems.append(item) }
            menu.addItem(item)
        }
        if agents.isEmpty {
            let none = NSMenuItem(title: String(localized: "No agents working", comment: "menu bar item: nothing waits or works"),
                                  action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: String(localized: "Open cmds", comment: "menu bar item"), action: #selector(openApp), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
    }

    /// Workspaces where an agent ran in this run, those that need the user first, then working, done, idle, stopped
    /// (sidebar order within each).
    private static func agentWorkspaces(_ workspaces: [Workspace]) -> [(Workspace, MenuBarIcon.State)] {
        let states: [(Workspace, MenuBarIcon.State)] = workspaces.compactMap { workspace in
            if AgentActivityStyle.needsUser(workspace) { return (workspace, .needsUser) }
            switch AgentActivityStyle.badge(for: workspace) {
            case .working: return (workspace, .working)
            case .needsInput: return (workspace, .needsUser)
            case .done: return (workspace, .done)
            case .idle: return (workspace, .idle)
            case .stopped: return (workspace, .stopped)
            case nil: return nil
            }
        }
        let order: [MenuBarIcon.State] = [.needsUser, .working, .done, .idle, .stopped]
        return order.flatMap { state in states.filter { $0.1 == state } }
    }

    /// The workspace name, and under it in small grey type the agent and what it does (or what it asks).
    private func workspaceItem(_ workspace: Workspace, state: MenuBarIcon.State) -> NSMenuItem {
        let item = NSMenuItem(title: workspace.displayTitle, action: #selector(openWorkspace(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = workspace.id
        item.image = MenuBarIcon.stateImage(state, phase: phase)
        var detail: [String] = []
        if let agent = workspace.primaryAgent?.usage.agent { detail.append(agent.displayName) }
        let doing = state == .needsUser ? workspace.notificationText ?? workspace.agentTopic : workspace.agentTopic
        if let doing, !doing.isEmpty { detail.append(doing) }
        let subagents = workspace.runningSubagentCount
        if subagents > 0 { detail.append("⧉ \(subagents)") }
        let title = NSMutableAttributedString(string: workspace.displayTitle, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        if !detail.isEmpty {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            title.append(NSAttributedString(string: "\n" + Self.truncated(detail.joined(separator: " · "), to: 56), attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: style,
            ]))
        }
        item.attributedTitle = title
        return item
    }

    private static func truncated(_ text: String, to length: Int) -> String {
        text.count > length ? String(text.prefix(length - 1)) + "…" : text
    }

    @objc private func openWorkspace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        showWorkspace(id)
    }

    @objc private func openApp() { showWorkspace(nil) }
}
