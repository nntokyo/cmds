import AppKit
import CmdsCore

/// Answers a waiting agent from the menu bar (#213): a panel under the menu bar item that takes the keyboard without
/// bringing the cmds window forward (a non-activating panel, like Ghostty's quick terminal). It shows the workspace,
/// its agent's state, a live mirror of the target pane's last screen lines, the agent's numbered choices as buttons
/// (`AgentPromptOptions`; 1–9 pick them while the reply field is empty), a reply field (Return pastes the text and
/// presses Return; empty, it only presses Return) and keys for Esc, ↑, ↓, Return and ⌃C.
/// "Open in cmds" (⌘↩) shows the pane in the main window; ⌘↑ / ⌘↓ go to the previous / next workspace of the menu;
/// Esc or a click elsewhere closes it.
@MainActor
final class MenuBarReplyPanel: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    /// The open panel, if any.
    private(set) static var current: MenuBarReplyPanel?

    private let controller: AppController
    /// Shows a workspace in the main window, at a pane if one is given.
    private let openInCmds: (String, String?) -> Void
    private weak var anchor: NSStatusBarButton?
    private let panel = ReplyPanelWindow(contentRect: NSRect(x: 0, y: 0, width: MenuBarReplyPanel.width, height: 400),
                                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private(set) var workspaceID: String
    /// The pane replies go to, chosen when the workspace is shown: the one that waits, else its agent's.
    private(set) var paneID: String?

    private let stateIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let paneLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(labelWithString: "")
    private let mirrorScroll = NSScrollView()
    private let mirror = NSTextView()
    private let questionLabel = NSTextField(wrappingLabelWithString: "")
    private let optionStack = NSStackView()
    private let promptBox = NSStackView()
    private let field = NSTextField()
    private var keyButtons: [NSButton] = []
    private let openButton = NSButton()

    private var timer: Timer?
    private var mouseMonitor: Any?
    private var closing = false
    /// What the mirror and the options show, so a refresh with the same screen does nothing.
    private var shownText: String?
    private var shownStyles: [[StyleRun]]?
    private(set) var prompt: AgentPromptOptions?

    static let width: CGFloat = 600
    /// Rows of the pane the mirror shows at once (it scrolls to the rest of the visible screen).
    private static let mirrorRows = 24
    private static let mirrorFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let mirrorBoldFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    /// The terminal's colours in the mirror: near black like the iPhone's screen (`TerminalPalette` is made for it),
    /// in light and dark mode alike.
    private static let mirrorForeground = NSColor(white: 0.92, alpha: 1)
    private static let mirrorBackground = NSColor(white: 0.08, alpha: 1)
    /// Refreshes per second while open.
    private static let refreshInterval: TimeInterval = 0.25

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

    // MARK: Layout

    private func build() {
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.delegate = self
        panel.identifier = NSUserInterfaceItemIdentifier("cmds.menuBarReply")
        panel.setAccessibilitySubrole(.floatingWindow)
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        panel.cancelHandler = { [weak self] in self?.close() }

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = background

        // Header: state mark, workspace, agent and state, the pane replies go to; "Open in cmds" on the right.
        stateIcon.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        for label in [detailLabel, paneLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        for label in [titleLabel, detailLabel, paneLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let titles = NSStackView(views: [titleLabel, detailLabel, paneLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1
        titles.setHuggingPriority(.init(1), for: .horizontal)  // the button stays at the right edge
        openButton.title = String(localized: "Open in cmds", comment: "menu bar reply panel: shows the pane in the main window")
        openButton.bezelStyle = .push
        openButton.controlSize = .small
        openButton.keyEquivalent = "\r"
        openButton.keyEquivalentModifierMask = .command
        openButton.toolTip = "⌘↩"
        openButton.target = self
        openButton.action = #selector(openInMainWindow)
        openButton.setContentHuggingPriority(.required, for: .horizontal)
        openButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let header = NSStackView(views: [stateIcon, titles, openButton])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 8

        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.textColor = .systemOrange
        noteLabel.isHidden = true

        // The mirror: the pane's screen, read only, scrolled to its bottom.
        mirror.isEditable = false
        mirror.isSelectable = true
        mirror.isRichText = true
        mirror.drawsBackground = true
        mirror.backgroundColor = Self.mirrorBackground
        mirror.textContainerInset = NSSize(width: 6, height: 6)
        mirror.isHorizontallyResizable = true
        mirror.isVerticallyResizable = true
        mirror.autoresizingMask = []
        mirror.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        mirror.textContainer?.widthTracksTextView = false
        mirror.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude)
        mirror.setAccessibilityLabel(String(localized: "Pane screen", comment: "menu bar reply panel: the mirror of the pane's screen (VoiceOver)"))
        mirrorScroll.documentView = mirror
        mirrorScroll.hasVerticalScroller = true
        mirrorScroll.hasHorizontalScroller = true
        mirrorScroll.autohidesScrollers = true
        mirrorScroll.drawsBackground = true
        mirrorScroll.backgroundColor = Self.mirrorBackground
        mirrorScroll.borderType = .noBorder
        mirrorScroll.wantsLayer = true
        mirrorScroll.layer?.cornerRadius = 6
        mirrorScroll.layer?.masksToBounds = true
        mirrorScroll.heightAnchor.constraint(equalToConstant: mirrorHeight()).isActive = true

        // The agent's choices.
        questionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        questionLabel.maximumNumberOfLines = 2
        questionLabel.preferredMaxLayoutWidth = Self.width - 24
        optionStack.orientation = .vertical
        optionStack.alignment = .leading
        optionStack.spacing = 4
        promptBox.orientation = .vertical
        promptBox.alignment = .leading
        promptBox.spacing = 6
        promptBox.addArrangedSubview(questionLabel)
        promptBox.addArrangedSubview(optionStack)
        promptBox.isHidden = true

        // Reply field and the key bar.
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = String(localized: "Reply (Return sends; empty, it presses Return)",
                                         comment: "menu bar reply panel: placeholder of the reply field")
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.bezelStyle = .roundedBezel
        field.delegate = self
        field.setAccessibilityLabel(String(localized: "Reply", comment: "menu bar reply panel: the reply field (VoiceOver)"))
        field.setAccessibilityIdentifier("menubar-reply-field")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        keyButtons = ReplyKey.allCases.map { key in
            let button = NSButton(title: key.title, target: self, action: #selector(sendKey(_:)))
            button.bezelStyle = .push
            button.controlSize = .small
            button.tag = key.rawValue
            button.setAccessibilityLabel(key.accessibilityLabel)
            button.toolTip = key.accessibilityLabel
            button.setContentHuggingPriority(.required, for: .horizontal)
            return button
        }
        let replyRow = NSStackView(views: [field] + keyButtons)
        replyRow.orientation = .horizontal
        replyRow.spacing = 4

        let hint = NSTextField(labelWithString: String(localized: "1–9 pick an option · ⌘↑ ⌘↓ other workspaces · ⌘↩ open in cmds · esc closes",
                                                       comment: "menu bar reply panel: keyboard hints"))
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [header, noteLabel, mirrorScroll, promptBox, replyRow, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            background.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        for view in [header, mirrorScroll, promptBox, replyRow, optionStack] as [NSView] {
            let container = view === optionStack ? promptBox : stack
            view.widthAnchor.constraint(equalTo: container.widthAnchor,
                                        constant: view === optionStack ? 0 : -24).isActive = true
        }
    }

    /// 24 rows of the mirror's font, fewer on a short screen.
    private func mirrorHeight() -> CGFloat {
        let line = NSLayoutManager().defaultLineHeight(for: Self.mirrorFont)
        let screen = anchor?.window?.screen ?? NSScreen.main
        let room = ((screen?.visibleFrame.height ?? 900) - 320) / line
        return CGFloat(max(8, min(Self.mirrorRows, Int(room)))) * line + 12
    }

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
    private func place() {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.width, height: content.fittingSize.height)
        let anchorFrame = anchor.flatMap { button in
            button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
        }
        let screen = anchor?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let top = panel.isVisible ? panel.frame.maxY : min(anchorFrame?.minY ?? visible.maxY, visible.maxY) - 4
        var x = (anchorFrame?.midX ?? visible.maxX) - size.width / 2
        x = min(max(x, visible.minX + 6), visible.maxX - size.width - 6)
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

    // MARK: Refresh

    /// Header, mirror and choices from the workspace and pane as they are now.
    func refresh() {
        guard !closing else { return }
        guard let workspace = controller.workspace(id: workspaceID) else {
            return showGone(String(localized: "This workspace has closed.", comment: "menu bar reply panel"))
        }
        updateHeader(workspace)
        guard let paneID, workspace.panes[paneID]?.terminal != nil,
              let screen = try? controller.screenState(paneID: paneID, styled: true) else {
            return showGone(String(localized: "This pane has closed.", comment: "menu bar reply panel"))
        }
        setInputEnabled(true)
        guard screen.text != shownText || screen.styles != shownStyles else { return }
        shownText = screen.text
        shownStyles = screen.styles
        var rows = screen.text.components(separatedBy: "\n")
        let lastText = rows.lastIndex { !$0.allSatisfy(\.isWhitespace) } ?? 0
        let bottom = min(rows.count - 1, max(lastText, screen.cursor?.row ?? 0))
        if bottom >= 0, bottom < rows.count - 1 { rows.removeSubrange((bottom + 1)...) }
        showMirror(rows, styles: screen.styles)
        showPrompt(AgentPromptOptions.parse(lines: rows))
    }

    private func updateHeader(_ workspace: Workspace) {
        let state = AgentOverview.summary(controller).entries.first { $0.id == workspace.id }?.state ?? .idle
        stateIcon.image = MenuBarIcon.stateImage(state, phase: 0.15)
        stateIcon.setAccessibilityLabel(AgentOverview.stateTitle(state))
        set(titleLabel, workspace.displayTitle)
        let detail = AgentOverview.detail(workspace, state: state, age: true)
        set(detailLabel, [AgentOverview.stateTitle(state), detail].filter { !$0.isEmpty }.joined(separator: " · "))
        if let paneID, let pane = workspace.panes[paneID] {
            let title = DefaultTitle.localized(pane.title)
            let order = workspace.orderedPanes
            if order.count > 1, let index = order.firstIndex(where: { $0 === pane }) {
                set(paneLabel, String(localized: "Replies go to pane \(index + 1) of \(order.count): \(title)",
                                      comment: "menu bar reply panel: the pane that gets the reply (number, panes, its title)"))
            } else {
                set(paneLabel, String(localized: "Replies go to \(title)", comment: "menu bar reply panel: the pane that gets the reply (its title)"))
            }
        } else {
            set(paneLabel, "")
        }
    }

    private func set(_ label: NSTextField, _ text: String) {
        if label.stringValue != text { label.stringValue = text }
    }

    private func showGone(_ note: String) {
        if noteLabel.isHidden || noteLabel.stringValue != note {
            noteLabel.stringValue = note
            noteLabel.isHidden = false
            showPrompt(nil)
            place()
        }
        setInputEnabled(false)
        openButton.isEnabled = controller.workspace(id: workspaceID) != nil
    }

    private func setInputEnabled(_ enabled: Bool) {
        if enabled, !noteLabel.isHidden {
            noteLabel.isHidden = true
            openButton.isEnabled = true
            place()
        }
        guard field.isEnabled != enabled else { return }
        field.isEnabled = enabled
        for button in keyButtons { button.isEnabled = enabled }
        if enabled, panel.isKeyWindow { panel.makeFirstResponder(field) }
    }

    private func showMirror(_ rows: [String], styles: [[StyleRun]]?) {
        let clip = mirrorScroll.contentView
        let wasAtBottom = clip.bounds.maxY >= mirror.frame.height - 4 || mirror.string.isEmpty
        mirror.textStorage?.setAttributedString(Self.attributed(rows, styles: styles))
        mirror.layoutManager?.ensureLayout(for: mirror.textContainer!)
        mirror.sizeToFit()
        guard wasAtBottom else { return }
        let y = max(0, mirror.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        mirrorScroll.reflectScrolledClipView(clip)
    }

    private func showPrompt(_ menu: AgentPromptOptions?) {
        guard menu != prompt else { return }
        prompt = menu
        for view in optionStack.arrangedSubviews { view.removeFromSuperview() }
        if let menu {
            questionLabel.stringValue = menu.question ?? ""
            questionLabel.isHidden = menu.question == nil
            for option in menu.options {
                let button = NSButton(title: "\(option.number)  \(option.label)", target: self, action: #selector(pickOption(_:)))
                button.bezelStyle = .push
                button.alignment = .left
                button.tag = option.number
                button.lineBreakMode = .byTruncatingTail
                button.toolTip = option.label
                if option.selected {
                    button.bezelColor = .controlAccentColor
                    button.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
                }
                button.setAccessibilityLabel(String(localized: "Option \(option.number): \(option.label)",
                                                    comment: "menu bar reply panel: a choice of the agent (VoiceOver)"))
                button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                optionStack.addArrangedSubview(button)
                button.widthAnchor.constraint(equalTo: optionStack.widthAnchor).isActive = true
            }
        }
        promptBox.isHidden = menu == nil
        place()
    }

    // MARK: Mirror text

    /// The rows in the mirror's font with their colours and attributes (`StyleRun` columns are cells: 2 for a wide
    /// character, `TerminalCells`); trailing blanks dropped.
    static func attributed(_ rows: [String], styles: [[StyleRun]]?) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let plain: [NSAttributedString.Key: Any] = [.font: mirrorFont, .foregroundColor: mirrorForeground]
        for (index, row) in rows.enumerated() {
            let text = String(row.reversed().drop { $0 == " " }.reversed())
            let runs = styles?[safe: index] ?? []
            if runs.isEmpty {
                result.append(NSAttributedString(string: text, attributes: plain))
            } else {
                var column = 0
                var next = 0
                var segment = ""
                var segmentStyle: TerminalStyle?
                func flush() {
                    guard !segment.isEmpty else { return }
                    result.append(NSAttributedString(string: segment, attributes: segmentStyle.map(attributes) ?? plain))
                    segment = ""
                }
                for character in text {
                    while next < runs.count, runs[next].end <= column { next += 1 }
                    let style = next < runs.count && runs[next].column <= column ? runs[next].style : nil
                    if style != segmentStyle {
                        flush()
                        segmentStyle = style
                    }
                    segment.append(character)
                    column += TerminalCells.width(of: character)
                }
                flush()
            }
            if index < rows.count - 1 { result.append(NSAttributedString(string: "\n", attributes: plain)) }
        }
        return result
    }

    /// As the iPhone draws a style (`TerminalStyle.colors`, also behind `PaneView.colors`): inverse swaps the colours,
    /// faint dims the text, invisible text takes the background's colour.
    private static func attributes(_ style: TerminalStyle) -> [NSAttributedString.Key: Any] {
        let (foreground, background) = style.colors(foreground: mirrorForeground, background: mirrorBackground,
                                                    color: color,
                                                    faint: { $0.withAlphaComponent(TerminalStyle.faintOpacity) })
        var attributes: [NSAttributedString.Key: Any] = [
            .font: style.attributes.contains(.bold) ? mirrorBoldFont : mirrorFont, .foregroundColor: foreground,
        ]
        if let background { attributes[.backgroundColor] = background }
        if style.attributes.contains(.underline) { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.attributes.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if style.attributes.contains(.italic) { attributes[.obliqueness] = 0.15 }
        return attributes
    }

    private static func color(_ color: TerminalColor) -> NSColor {
        let rgb = TerminalPalette.rgb(color)
        return NSColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }

    // MARK: Input

    /// Keys sent from the key bar.
    enum ReplyKey: Int, CaseIterable {
        case escape, up, down, enter, interrupt

        var title: String {
            switch self {
            case .escape: return "esc"
            case .up: return "↑"
            case .down: return "↓"
            case .enter: return "⏎"
            case .interrupt: return "^C"
            }
        }

        /// The bytes `typeText` turns into the key press (`GhosttySendText`).
        var bytes: String {
            switch self {
            case .escape: return "\u{1B}"
            case .up: return "\u{1B}[A"
            case .down: return "\u{1B}[B"
            case .enter: return "\r"
            case .interrupt: return "\u{03}"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .escape: return String(localized: "Send Escape", comment: "menu bar reply panel: key bar button (VoiceOver, tooltip)")
            case .up: return String(localized: "Send Up Arrow", comment: "menu bar reply panel: key bar button (VoiceOver, tooltip)")
            case .down: return String(localized: "Send Down Arrow", comment: "menu bar reply panel: key bar button (VoiceOver, tooltip)")
            case .enter: return String(localized: "Send Return", comment: "menu bar reply panel: key bar button (VoiceOver, tooltip)")
            case .interrupt: return String(localized: "Send Control-C", comment: "menu bar reply panel: key bar button (VoiceOver, tooltip)")
            }
        }
    }

    @objc private func sendKey(_ sender: NSButton) {
        guard let key = ReplyKey(rawValue: sender.tag) else { return }
        send(key)
        panel.makeFirstResponder(field)
    }

    func send(_ key: ReplyKey) { type(key.bytes) }

    @objc private func pickOption(_ sender: NSButton) {
        pick(sender.tag)
        panel.makeFirstResponder(field)
    }

    /// Types the option's digit. Claude Code picks an option on its number; Codex's approval list (`› 1. Yes,
    /// proceed (y)`) is believed to do the same (its selection lists accept digits), but this is not verified here —
    /// its own letter shortcuts (y, a) and ↑/↓ + Return from the key bar work either way.
    func pick(_ number: Int) {
        guard prompt?.options.contains(where: { $0.number == number }) == true else { return }
        type("\(number)")
    }

    /// The text as a paste (bracketed when the program asks for it), Return after `ScheduleRunTiming.enterDelay` (as
    /// a schedule's prompt: Return in the same burst would land in the paste); no text: Return only.
    func reply(_ text: String) {
        guard let paneID else { return }
        if text.isEmpty { return type("\r") }
        try? controller.sendText(paneID: paneID, text: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + ScheduleRunTiming.enterDelay) { [controller] in
            try? controller.typeText(paneID: paneID, text: "\r")
        }
        refreshSoon()
    }

    private func type(_ text: String) {
        guard let paneID else { return }
        try? controller.typeText(paneID: paneID, text: text)
        refreshSoon()
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.refresh() }
    }

    @objc private func openInMainWindow() {
        let workspaceID = workspaceID
        let paneID = paneID
        close()
        guard controller.workspace(id: workspaceID) != nil else { return }
        openInCmds(workspaceID, paneID)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            reply(field.stringValue)
            field.stringValue = ""
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    /// ⌘↑ / ⌘↓, and 1–9 while the reply field is empty (not while an input method composes).
    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() == true { return false }
        if modifiers == .command, event.keyCode == 126 || event.keyCode == 125 {
            move(event.keyCode == 126 ? -1 : 1)
            return true
        }
        if modifiers.isEmpty, field.stringValue.isEmpty, field.isEnabled, let characters = event.charactersIgnoringModifiers,
           let number = Int(characters), (1...9).contains(number),
           prompt?.options.contains(where: { $0.number == number }) == true {
            pick(number)
            return true
        }
        return false
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
private final class ReplyPanelWindow: NSPanel {
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
