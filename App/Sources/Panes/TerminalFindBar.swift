import AppKit

/// The find bar over the top-right corner of a terminal pane (⌘F, `TerminalFind`): search field, hit count, Match Case
/// and Regular Expression toggles, previous / next and close. The field keeps the keyboard while the bar is open.
final class TerminalFindBar: NSVisualEffectView, NSTextFieldDelegate {
    let field = FindField()
    let countLabel = NSTextField(labelWithString: "")
    let caseButton: NSButton
    let regexButton: NSButton

    var onChange: (() -> Void)?
    /// `true`: next (Return, ⌘G, up chevron: older output); `false`: previous.
    var onNavigate: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    var onFocus: (() -> Void)?

    init() {
        caseButton = Self.toggle(title: "Aa", tip: String(localized: "Match Case"))
        regexButton = Self.toggle(title: ".*", tip: String(localized: "Regular Expression"))
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        setAccessibilityIdentifier("terminal-find-bar")

        field.placeholderString = String(localized: "Find")
        field.font = .systemFont(ofSize: 12)
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.controlSize = .small
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.onFocus = { [weak self] in self?.onFocus?() }
        field.setAccessibilityIdentifier("terminal-find-field")
        field.widthAnchor.constraint(equalToConstant: 180).isActive = true

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        caseButton.target = self
        caseButton.action = #selector(optionChanged)
        regexButton.target = self
        regexButton.action = #selector(optionChanged)
        let next = Self.button(symbol: "chevron.up", tip: String(localized: "Next (⌘G, Return)"))
        next.target = self
        next.action = #selector(nextClicked)
        let previous = Self.button(symbol: "chevron.down", tip: String(localized: "Previous (⇧⌘G, ⇧Return)"))
        previous.target = self
        previous.action = #selector(previousClicked)
        let close = Self.button(symbol: "xmark", tip: String(localized: "Close (Esc)"))
        close.target = self
        close.action = #selector(closeClicked)

        let stack = NSStackView(views: [field, countLabel, caseButton, regexButton, next, previous, close])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var matchCase: Bool { caseButton.state == .on }
    var regex: Bool { regexButton.state == .on }

    /// Red text for a regular expression that does not compile.
    func setInvalid(_ invalid: Bool) {
        field.textColor = invalid ? .systemRed : .labelColor
    }

    private static func toggle(title: String, tip: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .recessed
        button.controlSize = .small
        button.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        button.refusesFirstResponder = true
        return button
    }

    private static func button(symbol: String, tip: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.bezelStyle = .recessed
        button.isBordered = false
        button.controlSize = .small
        button.toolTip = tip
        button.refusesFirstResponder = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    @objc private func optionChanged() { onChange?() }
    @objc private func nextClicked() { onNavigate?(true) }
    @objc private func previousClicked() { onNavigate?(false) }
    @objc private func closeClicked() { onClose?() }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) { onChange?() }

    /// Return / ⇧Return go to the next / previous hit, Esc closes; every other key edits the field.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            onNavigate?(!shift)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}

/// The find bar's field: reports when it takes the keyboard (a click on it focuses its pane).
final class FindField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }
}

/// Outline around the selected hit when the find bar searches the rows itself (Match Case, regular expressions:
/// libghostty's search, which highlights, is not used then). Never takes clicks.
final class TerminalFindMarker: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 2
        layer?.cornerRadius = 3
        layer?.borderColor = NSColor.systemOrange.cgColor
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.25).cgColor
        setAccessibilityIdentifier("terminal-find-marker")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
