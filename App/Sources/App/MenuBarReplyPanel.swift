import AppKit
import CmdsCore

/// Answers a waiting agent from the menu bar (#213): a panel under the menu bar item that takes the keyboard without
/// bringing the cmds window forward (a non-activating panel, like Ghostty's quick terminal). It shows the workspace,
/// its agent's state, a live mirror of the target pane's last screen lines, the agent's numbered choices as buttons
/// (`AgentPromptOptions`; 1–9 pick them while the reply field is empty), a reply field (Return pastes the text and
/// presses Return; empty, it only presses Return) and keys for Esc, ↑, ↓, Return and ⌃C.
/// "Open in cmds" (⌘↩) shows the pane in the main window; ⌘↑ / ⌘↓ go to the previous / next workspace of the menu;
/// Esc or a click elsewhere closes it.
///
/// Here: opening, placing and closing it, and which workspace and pane it shows. Its views are built in
/// `MenuBarReplyPanel+Layout.swift`, kept up to date in `+Refresh.swift` (header, mirror, choices) and answer the
/// keyboard and buttons in `+Input.swift` (#214).
@MainActor
final class MenuBarReplyPanel: NSObject, NSWindowDelegate {
    /// The open panel, if any.
    private(set) static var current: MenuBarReplyPanel?

    let controller: AppController
    /// Shows a workspace in the main window, at a pane if one is given.
    let openInCmds: (String, String?) -> Void
    private(set) weak var anchor: NSStatusBarButton?
    let panel = ReplyPanelWindow(contentRect: NSRect(x: 0, y: 0, width: MenuBarReplyPanel.width, height: 400),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private(set) var workspaceID: String
    /// The pane replies go to, chosen when the workspace is shown: the one that waits, else its agent's.
    private(set) var paneID: String?

    let stateIcon = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let paneLabel = NSTextField(labelWithString: "")
    let noteLabel = NSTextField(labelWithString: "")
    let mirrorScroll = NSScrollView()
    let mirror = NSTextView()
    let questionLabel = NSTextField(wrappingLabelWithString: "")
    let optionStack = NSStackView()
    let promptBox = NSStackView()
    let field = NSTextField()
    var keyButtons: [NSButton] = []
    let openButton = NSButton()

    private var timer: Timer?
    private var mouseMonitor: Any?
    private(set) var closing = false
    /// What the mirror and the options show, so a refresh with the same screen does nothing.
    var shownText: String?
    var shownStyles: [[StyleRun]]?
    var prompt: AgentPromptOptions?

    static let width: CGFloat = 600
    /// Refreshes per second while open.
    private static let refreshInterval: TimeInterval = 0.25
    /// The panel's gap below the menu bar item, and its least distance from the screen's sides.
    private static let anchorGap: CGFloat = 4
    private static let screenMargin: CGFloat = 6
    /// The screen assumed when there is none (headless).
    static let fallbackScreen = NSRect(x: 0, y: 0, width: 1440, height: 900)

    /// Opens the panel on workspace `workspaceID` under `anchor` (the menu bar item; the top right of the main screen
    /// without one), closing one that is open. `takeKeyboard` false (tests) shows it without making it key.
    @discardableResult
    static func present(workspaceID: String, controller: AppController, anchor: NSStatusBarButton?,
                        takeKeyboard: Bool = true, openInCmds: @escaping (String, String?) -> Void) -> MenuBarReplyPanel? {
        current?.close()
        guard controller.workspace(id: workspaceID) != nil else { return nil }
        let reply = MenuBarReplyPanel(workspaceID: workspaceID, controller: controller, anchor: anchor, openInCmds: openInCmds)
        current = reply
        reply.show(takeKeyboard: takeKeyboard)
        return reply
    }

    private init(workspaceID: String, controller: AppController, anchor: NSStatusBarButton?,
                 openInCmds: @escaping (String, String?) -> Void) {
        self.workspaceID = workspaceID
        self.controller = controller
        self.anchor = anchor
        self.openInCmds = openInCmds
        super.init()
        build()
        target(workspaceID)
    }

    /// The pane a reply to `workspace` goes to: the terminal pane that waits for the user (the one "Open in cmds"
    /// focuses), else the agent's, else the focused terminal pane.
    static func targetPane(in workspace: Workspace) -> Pane? {
        let terminals = workspace.orderedPanes.filter { $0.terminal != nil }
        return AgentOverview.waitingPane(in: terminals)
            ?? workspace.primaryAgent.flatMap { agent in terminals.first { $0 === agent.pane } }
            ?? terminals.first { $0.id == workspace.focusedPaneID }
            ?? terminals.first
    }

    // MARK: Showing and closing

    private func show(takeKeyboard: Bool) {
        refresh()
        place()
        if takeKeyboard {
            panel.makeKeyAndOrderFront(nil)  // key without activating cmds (a non-activating panel)
            panel.makeFirstResponder(field)
        } else {
            panel.orderFrontRegardless()
        }
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // A click in another app or on the desktop closes it, should it keep the keyboard (not in tests, where the
        // user's clicks elsewhere would close it under them).
        guard takeKeyboard else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    /// Under the menu bar item, kept on its screen; its top stays put when the content's height changes.
    func place() {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.width, height: content.fittingSize.height)
        let anchorFrame = anchor.flatMap { button in
            button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
        }
        let screen = anchor?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? Self.fallbackScreen
        let top = panel.isVisible ? panel.frame.maxY : min(anchorFrame?.minY ?? visible.maxY, visible.maxY) - Self.anchorGap
        var x = (anchorFrame?.midX ?? visible.maxX) - size.width / 2
        x = min(max(x, visible.minX + Self.screenMargin), visible.maxX - size.width - Self.screenMargin)
        panel.setFrame(NSRect(x: x, y: max(visible.minY, top - size.height), width: size.width, height: size.height),
                       display: true)
    }

    func close() {
        guard !closing else { return }
        closing = true
        if Self.current === self { Self.current = nil }
        timer?.invalidate()
        timer = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    // MARK: Workspace and pane

    /// Shows `workspaceID`, aimed at its pane that waits.
    private func target(_ workspaceID: String) {
        self.workspaceID = workspaceID
        paneID = controller.workspace(id: workspaceID).flatMap(Self.targetPane)?.id
        shownText = nil
        shownStyles = nil
        prompt = nil
        field.stringValue = ""
    }

    /// The previous (-1) or next (+1) workspace in the menu's order (`MenuBarSummary`); beeps at either end.
    func move(_ offset: Int) {
        let order = AgentOverview.summary(controller).entries.map(\.id)
        guard let index = order.firstIndex(of: workspaceID), order.indices.contains(index + offset) else {
            NSSound.beep()
            return
        }
        target(order[index + offset])
        refresh()
        place()
    }

    #if DEBUG
    var debugPanel: NSWindow { panel }
    var debugMirrorText: String { mirror.string }
    var debugHeader: [String] { [titleLabel.stringValue, detailLabel.stringValue, paneLabel.stringValue] }
    var debugNote: String? { noteLabel.isHidden ? nil : noteLabel.stringValue }
    var debugField: NSTextField { field }
    func debugOpenInCmds() { openInMainWindow() }
    #endif
}

/// Borderless and non-activating, but takes the keyboard; key presses go to `keyHandler` first.
final class ReplyPanelWindow: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    var cancelHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }

    /// Esc outside the reply field (the mirror, a button).
    override func cancelOperation(_ sender: Any?) { cancelHandler?() }
}
