import AppKit
import CmdsCore

/// The menu bar reply panel's views (#213): header, note, mirror, the agent's choices, reply field and key bar, hints.
extension MenuBarReplyPanel {
    /// Space around the content and the panel's corner radius.
    private static let margin: CGFloat = 12
    private static let cornerRadius: CGFloat = 10
    /// Rows of the pane the mirror shows at once (it scrolls to the rest of the visible screen), and at least.
    private static let mirrorRows = 24
    private static let minimumMirrorRows = 8
    /// Inset of the mirror's text, on each side.
    private static let mirrorInset: CGFloat = 6
    /// Screen height the rest of the panel and the menu bar take, which the mirror leaves free.
    private static let heightBesideMirror: CGFloat = 320

    func build() {
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
        background.layer?.cornerRadius = Self.cornerRadius
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = background

        let header = buildHeader()

        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.textColor = .systemOrange
        noteLabel.isHidden = true

        buildMirror()
        buildPromptBox()
        let replyRow = buildReplyRow()

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
        stack.edgeInsets = NSEdgeInsets(top: Self.margin, left: Self.margin, bottom: 10, right: Self.margin)
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
                                        constant: view === optionStack ? 0 : -2 * Self.margin).isActive = true
        }
    }

    /// State mark, workspace, agent and state, the pane replies go to; "Open in cmds" on the right.
    private func buildHeader() -> NSStackView {
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
        return header
    }

    /// The mirror: the pane's screen, read only, scrolled to its bottom.
    private func buildMirror() {
        mirror.isEditable = false
        mirror.isSelectable = true
        mirror.isRichText = true
        mirror.drawsBackground = true
        mirror.backgroundColor = Self.mirrorBackground
        mirror.textContainerInset = NSSize(width: Self.mirrorInset, height: Self.mirrorInset)
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
    }

    /// The agent's choices: its question and a button per option (`showPrompt` fills them).
    private func buildPromptBox() {
        questionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        questionLabel.maximumNumberOfLines = 2
        questionLabel.preferredMaxLayoutWidth = Self.width - 2 * Self.margin
        optionStack.orientation = .vertical
        optionStack.alignment = .leading
        optionStack.spacing = 4
        promptBox.orientation = .vertical
        promptBox.alignment = .leading
        promptBox.spacing = 6
        promptBox.addArrangedSubview(questionLabel)
        promptBox.addArrangedSubview(optionStack)
        promptBox.isHidden = true
    }

    /// Reply field and the key bar.
    private func buildReplyRow() -> NSStackView {
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
        return replyRow
    }

    /// `mirrorRows` rows of the mirror's font, fewer on a short screen (at least `minimumMirrorRows`).
    private func mirrorHeight() -> CGFloat {
        let line = NSLayoutManager().defaultLineHeight(for: Self.mirrorFont)
        let screen = anchor?.window?.screen ?? NSScreen.main
        let room = ((screen?.visibleFrame.height ?? Self.fallbackScreen.height) - Self.heightBesideMirror) / line
        return CGFloat(max(Self.minimumMirrorRows, min(Self.mirrorRows, Int(room)))) * line + 2 * Self.mirrorInset
    }
}
