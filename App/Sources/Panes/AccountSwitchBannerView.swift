import AppKit

/// Slim bar at the top of a terminal pane whose Claude account hit its limit (AppController+Accounts):
/// "“work” hit its limit (resets 15:00)." with Continue with “personal” / Dismiss; while switching
/// "Switching to “personal” once Claude Code is idle…" with Cancel; when it cannot switch, why (and Settings… when
/// the sessions are not shared yet, Continue at 15:01 when every account is limited: a schedule). Same look as `AgentResumeBannerView`; never takes the keyboard.
final class AccountSwitchBannerView: NSVisualEffectView {
    enum State {
        case offered(text: String, target: String)
        case switching(text: String)
        /// `continueAt`: the time a "continue" schedule would run (every other account is limited too).
        case problem(text: String, canShare: Bool, continueAt: String? = nil)
    }

    var onSwitch: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onSettings: (() -> Void)?
    var onContinueLater: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    init(state: State) {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        setAccessibilityIdentifier("cmds.accountSwitchBanner")

        let icon = NSImageView(image: NSImage(systemSymbolName: "person.2.circle", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = .systemOrange
        icon.setContentHuggingPriority(.required, for: .horizontal)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(label)
        switch state {
        case .offered(let text, let target):
            label.stringValue = text
            stack.addArrangedSubview(button(String(localized: "Continue with “\(target)”"), #selector(switchClicked), primary: true))
            stack.addArrangedSubview(button(String(localized: "Dismiss"), #selector(dismissClicked)))
        case .switching(let text):
            label.stringValue = text
            stack.addArrangedSubview(button(String(localized: "Cancel"), #selector(dismissClicked)))
        case .problem(let text, let canShare, let continueAt):
            label.stringValue = text
            if let continueAt {
                let later = button(String(localized: "Continue at \(continueAt)"), #selector(continueLaterClicked), primary: true)
                later.toolTip = String(localized: "Type “continue” into this session when the limit resets (Window › Schedules)")
                stack.addArrangedSubview(later)
            }
            if canShare { stack.addArrangedSubview(button(String(localized: "Settings…"), #selector(settingsClicked))) }
            stack.addArrangedSubview(button(String(localized: "Dismiss"), #selector(dismissClicked)))
        }
        toolTip = label.stringValue
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

    /// Stays out of the keyboard loop: the terminal underneath keeps first responder.
    override var acceptsFirstResponder: Bool { false }

    private func button(_ title: String, _ action: Selector, primary: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.refusesFirstResponder = true
        if primary { button.bezelColor = .controlAccentColor }
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    @objc private func switchClicked() { onSwitch?() }
    @objc private func dismissClicked() { onDismiss?() }
    @objc private func settingsClicked() { onSettings?() }
    @objc private func continueLaterClicked() { onContinueLater?() }
}
