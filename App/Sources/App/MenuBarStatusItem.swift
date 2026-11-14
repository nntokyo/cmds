import AppKit
import Combine
import CmdsCore

/// The menu bar item (#95), drawn rather than written: the cmds glyph with an orange badge (workspaces that need the
/// user, orange in the sidebar) and an accent badge circled by a turning arc while agents work. Its menu shows ring
/// charts for CPU, memory, the agents' account limits and their context windows, then every workspace with an agent and a mark for what it
/// is doing (and, when it needs the user, since when); choosing one (or ⌘1…⌘9) opens the reply panel on it
/// (`MenuBarReplyPanel`, #213), or with ⌥ (or that setting off) brings cmds forward on it. A red dot on the icon warns
/// of a limit at 95 % or critical memory pressure (#105). Settings › Menu Bar chooses what shows.
@MainActor
final class MenuBarStatusItem: NSObject, NSMenuDelegate {
    /// The app's item (`debug.menubar_reply`).
    private(set) static weak var shared: MenuBarStatusItem?
    private let controller: AppController
    private let showWorkspace: (String?, String?) -> Void
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
        /// The voice assistant (#243): nil off, else whether it is paused.
        var assistantPaused: Bool?
    }
    /// Pulses the assistant's dot while it listens.
    private var assistantPulse: Timer?
    private var assistantPhase = 0.0

    /// One spinner turn takes this long, in `steps` frames.
    private static let turn: TimeInterval = 1.2
    private static let steps = 12

    /// `showWorkspace` brings the main window forward, on a workspace if one is given, at a pane if one is given (else
    /// at the workspace's pane that waits).
    init(controller: AppController, showWorkspace: @escaping (String?, String?) -> Void) {
        self.controller = controller
        self.showWorkspace = showWorkspace
        super.init()
    }

    func start() {
        Self.shared = self
        subscription = controller.changes.sink { [weak self] _ in self?.update() }
        usageSubscription = controller.usageChanges.sink { [weak self] in
            guard let self else { return }
            self.update()  // the warning dot follows limits and memory pressure
            if self.menuIsOpen { self.updateDashboard() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: AppSettings.didChange, object: nil)
        if #available(macOS 26.0, *) {
            NotificationCenter.default.addObserver(self, selector: #selector(assistantChanged), name: AssistantController.didChange,
                                                   object: nil)
        }
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

    @objc private func assistantChanged() { update() }

    /// The assistant's state for the icon: nil off (or below macOS 26), else whether it is paused.
    private var assistantPaused: Bool? {
        guard #available(macOS 26.0, *), let assistant = AssistantController.shared, assistant.isOn else { return nil }
        return assistant.isPaused
    }

    /// A slow pulse of the assistant's dot while it listens (not with Reduce Motion or the animation off).
    private func updateAssistantPulse(_ paused: Bool?) {
        let animate = paused == false && item != nil && AppSettings.shared.menuBar(.animation)
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate, assistantPulse == nil {
            let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.assistantPhase = (self.assistantPhase + 0.15 / 2.4).truncatingRemainder(dividingBy: 1)
                    self.drawStatusImage()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            assistantPulse = timer
        } else if !animate, let timer = assistantPulse {
            timer.invalidate()
            assistantPulse = nil
            assistantPhase = 0
        }
    }

    @objc private func motionPreferenceChanged() {
        appliedCounts = nil
        update()
    }

    private var summary: MenuBarSummary { AgentOverview.summary(controller) }

    private func update() {
        guard let button = item?.button else { return }
        let summary = summary
        let settings = AppSettings.shared
        let counts = Counts(needingUser: summary.needingUserCount,
                            working: settings.menuBar(.workingBadge) ? summary.workingCount : 0,
                            warning: settings.menuBar(.warningDot) ? AgentOverview.warning(controller) : nil,
                            assistantPaused: assistantPaused)
        updateSpinner(working: counts.working > 0)
        updateAssistantPulse(counts.assistantPaused)
        guard counts != appliedCounts else { return }
        appliedCounts = counts
        drawStatusImage()
        let description = Self.description(counts)
        button.setAccessibilityLabel(description)
        button.toolTip = description
    }

    private func drawStatusImage() {
        guard let button = item?.button, let counts = appliedCounts else { return }
        let assistant = counts.assistantPaused.map { paused in
            (alpha: paused ? 0.8 : 0.65 + 0.35 * CGFloat(sin(assistantPhase * 2 * .pi) + 1) / 2, paused: paused)
        }
        button.image = MenuBarIcon.statusImage(needingUser: counts.needingUser, working: counts.working, phase: phase,
                                               warning: counts.warning != nil, assistant: assistant)
    }

    /// Runs the spinner timer while agents work, unless the user turned the animation off (Settings › Menu Bar) or asked
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
        if let paused = counts.assistantPaused {
            text += "\n" + (paused ? String(localized: "Assistant paused", comment: "menu bar item tooltip")
                                    : String(localized: "Assistant listening", comment: "menu bar item tooltip"))
        }
        return text
    }

    // MARK: Menu

    /// The rings the user chose to see (Settings › Menu Bar); false when none.
    @discardableResult
    private func updateDashboard() -> Bool {
        let settings = AppSettings.shared
        let system = settings.menuBar(.systemRings)
        let limits = settings.menuBar(.limitRings) ? controller.activeAgentLimits() : []
        let contexts = settings.menuBar(.contextRings) ? AgentOverview.contexts(controller) : []
        dashboard.update(sample: controller.systemSample, agentLimits: limits, contexts: contexts, showsMachine: system)
        return system || !limits.isEmpty || !contexts.isEmpty
    }

    /// The reply panel closes: the menu may open it on another workspace.
    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        MenuBarReplyPanel.current?.close()
    }

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
        let reply = AppSettings.shared.menuBar(.replyPanel)
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
            if reply {
                // With ⌥ held: bring cmds forward on it, as before the reply panel.
                let open = workspaceItem(workspace, state: state)
                open.action = #selector(openWorkspaceInCmds(_:))
                if #available(macOS 14.4, *) {
                    open.subtitle = String(localized: "Open in cmds", comment: "menu bar reply panel: shows the pane in the main window")
                }
                open.keyEquivalent = item.keyEquivalent
                open.keyEquivalentModifierMask = item.keyEquivalentModifierMask.union(.option)
                open.isAlternate = true
                if state == .working { workingMenuItems.append(open) }
                itemStates[ObjectIdentifier(open)] = state
                menu.addItem(open)
            }
        }
        if entries.isEmpty, AppSettings.shared.menuBar(.workspaces) {
            let none = NSMenuItem(title: String(localized: "No agents working", comment: "menu bar item: nothing waits or works"),
                                  action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        addAssistantItems(to: menu)
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
        let detail = AgentOverview.detail(workspace, state: state, age: true)
        // The agent and its task under the name, in the menu's own secondary line (a "\n" in the title would be cut
        // off: menus size such rows for one line, #101). Before macOS 14.4 only the name shows.
        if !detail.isEmpty, #available(macOS 14.4, *) {
            item.subtitle = Self.truncated(detail, to: 56)
        }
        return item
    }

    private static func truncated(_ text: String, to length: Int) -> String {
        text.count > length ? String(text.prefix(length - 1)) + "…" : text
    }

    /// The reply panel on the workspace (Settings › Menu Bar › Reply from the menu bar), else cmds on it.
    @objc private func openWorkspace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        guard AppSettings.shared.menuBar(.replyPanel) else { return showWorkspace(id, nil) }
        // After the menu has closed, so the panel takes the keyboard.
        DispatchQueue.main.async { [weak self] in self?.presentReply(workspaceID: id) }
    }

    @objc private func openWorkspaceInCmds(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        showWorkspace(id, nil)
    }

    /// The reply panel on `workspaceID`, under the item. `takeKeyboard` false: tests (it must not take the keyboard).
    @discardableResult
    func presentReply(workspaceID: String, takeKeyboard: Bool = true) -> MenuBarReplyPanel? {
        MenuBarReplyPanel.present(workspaceID: workspaceID, controller: controller, anchor: item?.button,
                                  takeKeyboard: takeKeyboard) { [weak self] workspace, pane in
            self?.showWorkspace(workspace, pane)
        }
    }

    /// The voice assistant (#243, macOS 26): on / off, pause / resume listening.
    private func addAssistantItems(to menu: NSMenu) {
        guard #available(macOS 26.0, *), let assistant = AssistantController.shared, assistant.isUnlocked else { return }
        let toggle = NSMenuItem(title: String(localized: "Assistant", comment: "menu bar item: turns the voice assistant on or off"),
                                action: #selector(toggleAssistant), keyEquivalent: "")
        toggle.target = self
        toggle.state = assistant.isOn ? .on : .off
        menu.addItem(toggle)
        if assistant.isOn {
            let pause = NSMenuItem(title: assistant.isPaused
                                   ? String(localized: "Resume Listening", comment: "menu bar item: assistant")
                                   : String(localized: "Pause Listening", comment: "menu bar item: assistant"),
                                   action: #selector(pauseAssistant), keyEquivalent: "")
            pause.target = self
            pause.indentationLevel = 1
            menu.addItem(pause)
            if let app = assistant.pausedForApp {
                // Paused by itself while another app records (#278), or, a Debug build, while the released app's
                // assistant listens (#295).
                let title = assistant.pausedForCmds
                    ? String(localized: "Paused while the assistant in \(app) is listening", comment: "menu bar item: assistant, disabled; a Debug build pauses while the released cmds' assistant listens")
                    : String(localized: "Paused while \(app) uses the microphone", comment: "menu bar item: assistant, disabled")
                let reason = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                reason.isEnabled = false
                reason.indentationLevel = 1
                menu.addItem(reason)
                if let name = assistant.ignorableRecorderName {
                    // An app that keeps the microphone open never pauses it again (#295).
                    let ignore = NSMenuItem(title: String(localized: "Don’t Pause for \(name)", comment: "menu bar item: assistant; the app recording never pauses it again (Settings › Assistant clears the list)"),
                                            action: #selector(ignoreRecorder), keyEquivalent: "")
                    ignore.target = self
                    ignore.indentationLevel = 1
                    menu.addItem(ignore)
                }
            }
        }
        menu.addItem(.separator())
    }

    @objc private func toggleAssistant() {
        guard #available(macOS 26.0, *), let assistant = AssistantController.shared else { return }
        assistant.isOn ? assistant.turnOff() : assistant.turnOn()
    }

    @objc private func pauseAssistant() {
        guard #available(macOS 26.0, *), let assistant = AssistantController.shared else { return }
        assistant.isPaused ? assistant.resume() : assistant.pause()
    }

    /// "Don't Pause for …" (#295).
    @objc private func ignoreRecorder() {
        guard #available(macOS 26.0, *), let assistant = AssistantController.shared else { return }
        assistant.ignoreRecorder()
    }

    @objc private func openApp() { showWorkspace(nil, nil) }

    @objc private func openSettings() {
        NSApp.activate()
        SettingsWindowController.shared.show(tab: .menuBar)
    }
}
