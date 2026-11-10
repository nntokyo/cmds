import AppKit
import CmdsCore

/// The menu bar reply panel kept up to date (#213): header, the mirror of the pane's screen, the agent's choices, and
/// a note when the pane or workspace has closed.
extension MenuBarReplyPanel {
    static let mirrorFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let mirrorBoldFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    /// The terminal's colours in the mirror: near black like the iPhone's screen (`TerminalPalette` is made for it),
    /// in light and dark mode alike.
    static let mirrorForeground = NSColor(white: 0.92, alpha: 1)
    static let mirrorBackground = NSColor(white: 0.08, alpha: 1)
    /// Slant of italic text (the monospaced system font has no italic face).
    private static let italicObliqueness = 0.15
    /// How near its end (points) the mirror counts as scrolled to the bottom, so new lines keep it there.
    private static let bottomTolerance: CGFloat = 4
    /// A still frame of the working mark's turning arc (`MenuBarIcon.stateImage`).
    private static let stateIconPhase = 0.15

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
        stateIcon.image = MenuBarIcon.stateImage(state, phase: Self.stateIconPhase)
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
        let wasAtBottom = clip.bounds.maxY >= mirror.frame.height - Self.bottomTolerance || mirror.string.isEmpty
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
        if style.attributes.contains(.italic) { attributes[.obliqueness] = italicObliqueness }
        return attributes
    }

    private static func color(_ color: TerminalColor) -> NSColor {
        let rgb = TerminalPalette.rgb(color)
        return NSColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }
}
