import AppKit

/// Slim bar at the top of a terminal pane offering to resume the agent session that ran there before cmds restarted:
/// "Resume Claude Code session “Fix login” (Opus, 2 h ago)" with Resume / Resume All / Dismiss. While a resume
/// waits for the shell prompt it shows "Resuming … — waiting for the shell" with Cancel. Never takes the keyboard.
final class AgentResumeBannerView: NSVisualEffectView {
    enum State {
        case offered(summary: String, command: String, others: Int)
        case waiting(summary: String)
    }

    var onResume: (() -> Void)?
    var onResumeAll: (() -> Void)?
    var onDismiss: (() -> Void)?

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

        let icon = NSImageView(image: NSImage(systemSymbolName: "arrow.counterclockwise.circle", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = .controlAccentColor
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
        case .offered(let summary, let command, let others):
            label.stringValue = "Resume \(summary)"
            toolTip = "Types into this pane's shell:\n\(command)"
            stack.addArrangedSubview(button("Resume", #selector(resumeClicked), primary: true))
            if others > 0 { stack.addArrangedSubview(button("Resume All (\(others + 1))", #selector(resumeAllClicked))) }
            stack.addArrangedSubview(button("Dismiss", #selector(dismissClicked)))
        case .waiting(let summary):
            label.stringValue = "Resuming \(summary) — waiting for the shell prompt…"
            stack.addArrangedSubview(button("Cancel", #selector(dismissClicked)))
        }
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

    @objc private func resumeClicked() { onResume?() }
    @objc private func resumeAllClicked() { onResumeAll?() }
    @objc private func dismissClicked() { onDismiss?() }
}
