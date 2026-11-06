import AppKit
import Combine
import CmdsCore

/// The menu bar item (#95), drawn rather than written: the cmds glyph with an orange badge (workspaces that need the
/// user, orange in the sidebar) and an accent badge circled by a turning arc while agents work. Its menu shows ring
/// charts for CPU, memory and the agents' account limits, then every workspace with an agent and a mark for what it
/// is doing (and, when it needs the user, since when); choosing one (or ⌘1…⌘9) brings cmds forward on it. A red dot
/// on the icon warns of a limit at 95 % or critical memory pressure (#105). Settings › Agents › Show in menu bar.
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
    /// State of each workspace item in the open menu, to redraw its mark when it is highlighted.
    private var itemStates: [ObjectIdentifier: MenuBarSummary.State] = [:]
    private weak var highlightedItem: NSMenuItem?

    /// What the status bar image shows; it is redrawn only when this changes (or the spinner turns).
    private struct Counts: Equatable {
        var needingUser: Int
        var working: Int
        /// Why the red warning dot shows, nil when it does not.
        var warning: String?
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
            guard let self else { return }
            self.update()  // the warning dot follows limits and memory pressure
            if self.menuIsOpen { self.updateDashboard() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: AppSettings.didChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(motionPreferenceChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                          object: nil)
        settingsChanged()
    }

    /// Shows or removes the item; also when the animation setting changed.
    @objc private func settingsChanged() {
        if AppSettings.shared.showInMenuBar, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
        } else if !AppSettings.shared.showInMenuBar, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
        appliedCounts = nil
        update()
        if item == nil { updateSpinner(working: false) }
    }

    @objc private func motionPreferenceChanged() {
        appliedCounts = nil
        update()
    }

    private var summary: MenuBarSummary {
        MenuBarSummary(controller.workspaces.map { workspace in
            MenuBarSummary.Entry(id: workspace.id, needsUser: AgentActivityStyle.needsUser(workspace),
                                 activity: Self.state(AgentActivityStyle.badge(for: workspace)))
        })
    }

    private static func state(_ badge: AgentActivityStyle.Badge?) -> MenuBarSummary.State? {
        switch badge {
        case .working: return .working
        case .needsInput: return .needsUser
        case .done: return .done
        case .idle: return .idle
        case .stopped: return .stopped
        case nil: return nil
        }
    }

    private func update() {
        guard let button = item?.button else { return }
        let summary = summary
        let settings = AppSettings.shared
        let counts = Counts(needingUser: summary.needingUserCount,
                            working: settings.menuBar(.workingBadge) ? summary.workingCount : 0,
                            warning: settings.menuBar(.warningDot) ? warning() : nil)
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
        button.image = MenuBarIcon.statusImage(needingUser: counts.needingUser, working: counts.working, phase: phase,
                                               warning: counts.warning != nil)
    }

    /// An account limit at 95 % or more, or critical memory pressure: what the red dot warns of, for its tooltip.
    private func warning() -> String? {
        var reasons: [String] = []
        for limits in controller.activeAgentLimits() {
            for limit in limits.ordered where UsageLevel(percent: limit.usedPercent) == .critical {
                reasons.append("\(limits.agent.displayName) \(AgentFormat.limitLabel(limit, strings: .localized)) \(AgentFormat.percent(limit.usedPercent))")
            }
        }
        if controller.systemSample?.stats.pressure == .critical {
            reasons.append(String(localized: "Memory pressure critical", comment: "menu bar item tooltip: why the red dot shows"))
        }
        return reasons.isEmpty ? nil : reasons.joined(separator: ", ")
    }

    /// Runs the spinner timer while agents work, unless the user turned the animation off (Settings › Agents) or asked
    /// for reduced motion: then the arc stands still.
    private func updateSpinner(working: Bool) {
        let animate = working && item != nil && AppSettings.shared.menuBar(.animation)
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
        for item in workingMenuItems {
            item.image = MenuBarIcon.stateImage(.working, phase: phase, highlighted: item === highlightedItem)
        }
    }

    /// Tooltip and VoiceOver label.
    private static func description(_ counts: Counts) -> String {
        var text = "cmds"
        if counts.needingUser > 0 || counts.working > 0 {
            text += " — " + String(localized: "\(counts.needingUser) need you, \(counts.working) working",
                                   comment: "menu bar item: workspaces waiting for the user, and with an agent working")
        }
        if let warning = counts.warning { text += "\n⚠︎ " + warning }
        return text
    }

    // MARK: Menu

    /// The rings the user chose to see (Settings › Menu Bar); false when none.
    @discardableResult
    private func updateDashboard() -> Bool {
        let settings = AppSettings.shared
        let system = settings.menuBar(.systemRings)
        let limits = settings.menuBar(.limitRings) ? controller.activeAgentLimits() : []
        dashboard.update(sample: controller.systemSample, agentLimits: limits, showsMachine: system)
        return system || !limits.isEmpty
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        workingMenuItems = []
        itemStates = [:]
        highlightedItem = nil
    }

    /// The highlighted workspace's mark turns white, the one left behind gets its colours back.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        let previous = highlightedItem
        highlightedItem = item
        for changed in [previous, item].compactMap({ $0 }) {
            guard let state = itemStates[ObjectIdentifier(changed)] else { continue }
            changed.image = MenuBarIcon.stateImage(state, phase: phase, highlighted: changed === item)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if updateDashboard() {
            menu.addItem(dashboardItem)
            menu.addItem(.separator())
        }
        workingMenuItems = []
        itemStates = [:]
        highlightedItem = nil
        let entries = AppSettings.shared.menuBar(.workspaces) ? summary.entries : []
        for (index, entry) in entries.enumerated() {
            guard let workspace = controller.workspace(id: entry.id), let state = entry.state else { continue }
            let item = workspaceItem(workspace, state: state)
            if index < 9 {  // ⌘1…⌘9 while the menu is open, in menu order
                item.keyEquivalent = "\(index + 1)"
                item.keyEquivalentModifierMask = .command
            }
            if state == .working { workingMenuItems.append(item) }
            itemStates[ObjectIdentifier(item)] = state
            menu.addItem(item)
        }
        if entries.isEmpty, AppSettings.shared.menuBar(.workspaces) {
            let none = NSMenuItem(title: String(localized: "No agents working", comment: "menu bar item: nothing waits or works"),
                                  action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: String(localized: "Open cmds", comment: "menu bar item"), action: #selector(openApp), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settings = NSMenuItem(title: String(localized: "Menu Bar Settings…", comment: "menu bar item: opens Settings"),
                                  action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
    }

    /// The workspace name, and under it in small grey type the agent and what it does (or what it asks).
    private func workspaceItem(_ workspace: Workspace, state: MenuBarSummary.State) -> NSMenuItem {
        let item = NSMenuItem(title: workspace.displayTitle, action: #selector(openWorkspace(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = workspace.id
        item.image = MenuBarIcon.stateImage(state, phase: phase)
        var detail: [String] = []
        // How long it has waited: what to answer first.
        if state == .needsUser, let since = workspace.panes.values.filter(\.attention).compactMap(\.attentionDate).max() {
            detail.append(AgentFormat.age(since, strings: .localized))
        }
        if let agent = workspace.primaryAgent?.usage.agent { detail.append(agent.displayName) }
        let doing = state == .needsUser ? workspace.notificationText ?? workspace.agentTopic : workspace.agentTopic
        if let doing, !doing.isEmpty { detail.append(doing) }
        let subagents = workspace.runningSubagentCount
        if subagents > 0 { detail.append("⧉ \(subagents)") }
        // The agent and its task under the name, in the menu's own secondary line (a "\n" in the title would be cut
        // off: menus size such rows for one line, #101). Before macOS 14.4 only the name shows.
        if !detail.isEmpty, #available(macOS 14.4, *) {
            item.subtitle = Self.truncated(detail.joined(separator: " · "), to: 56)
        }
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

    @objc private func openSettings() {
        NSApp.activate()
        SettingsWindowController.shared.show(tab: .menuBar)
    }
}
