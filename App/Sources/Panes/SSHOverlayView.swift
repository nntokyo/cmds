import AppKit

/// Covers an SSH pane whose `ssh` is not running: "Disconnected — ssh home" with Reconnect (⌘R / Return) and Close.
/// Takes the keyboard while shown, so keys never reach the dead terminal (libghostty would close it on any key).
final class SSHOverlayView: NSView {
    enum State {
        /// Restored from the session: never connects on its own.
        case notConnected
        case disconnected
    }

    var onReconnect: (() -> Void)?
    var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let reconnectButton = NSButton(title: String(localized: "Reconnect (⌘R)"), target: nil, action: nil)
    private let closeButton = NSButton(title: String(localized: "Close Pane"), target: nil, action: nil)

    init(host: String, state: State) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.82).cgColor

        let icon = NSImageView(image: NSImage(systemSymbolName: "network.slash", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 28, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.alignment = .center
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.preferredMaxLayoutWidth = 360
        switch state {
        case .notConnected:
            titleLabel.stringValue = String(localized: "Not connected — ssh \(host)")
            detailLabel.stringValue = String(localized: "SSH panes from the last session connect only when you ask.")
            reconnectButton.title = String(localized: "Connect (⌘R)")
        case .disconnected:
            titleLabel.stringValue = String(localized: "Disconnected — ssh \(host)")
            detailLabel.stringValue = String(localized: "The ssh process exited. Reconnect runs the same command again.")
        }
        reconnectButton.bezelStyle = .rounded
        reconnectButton.target = self
        reconnectButton.action = #selector(reconnectClicked)
        closeButton.bezelStyle = .rounded
        closeButton.target = self
        closeButton.action = #selector(closeClicked)

        let buttons = NSStackView(views: [closeButton, reconnectButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let stack = NSStackView(views: [icon, titleLabel, detailLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(14, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    /// Clicks anywhere on the pane focus the overlay (and the pane), never the terminal underneath.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onFocus?()
    }

    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        onFocus?()
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReconnect?() // Return, keypad Enter
        default: NSSound.beep()
        }
    }

    @objc private func reconnectClicked() { onReconnect?() }
    @objc private func closeClicked() { onClose?() }
}
