import AppKit

/// Hosts a pane's content view and draws the focus outline and the attention ring above it.
final class PaneContainerView: NSView {
    let paneID: String
    private let ring = AttentionRingView()

    var attention = false {
        didSet { if attention != oldValue { updateRing() } }
    }

    /// Subtle outline for the focused pane when the workspace shows several panes.
    var showsFocus = false {
        didSet { if showsFocus != oldValue { updateRing() } }
    }

    init(paneID: String, content: NSView) {
        self.paneID = paneID
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        wantsLayer = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        ring.frame = bounds
        ring.autoresizingMask = [.width, .height]
        addSubview(ring)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        // Keep the ring above content that engines may add later.
        if subview !== ring, ring.superview === self { addSubview(ring, positioned: .above, relativeTo: nil) }
    }

    private func updateRing() {
        ring.state = attention ? .attention : (showsFocus ? .focused : .off)
    }
}

/// Non-interactive overlay: a pulsing colored border when lit.
final class AttentionRingView: NSView {
    enum State { case off, focused, attention }

    var state: State = .off {
        didSet { if state != oldValue { apply() } }
    }

    private static let ringColor = NSColor.systemOrange
    private static let pulseKey = "cmds.pulse"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = false
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { apply() } // layer animations do not survive re-parenting reliably
    }

    private func apply() {
        guard let layer else { return }
        layer.removeAnimation(forKey: Self.pulseKey)
        switch state {
        case .off:
            layer.borderWidth = 0
            layer.shadowOpacity = 0
        case .focused:
            layer.borderWidth = 1
            layer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor
            layer.shadowOpacity = 0
        case .attention:
            layer.borderWidth = 2.5
            layer.borderColor = Self.ringColor.cgColor
            layer.shadowColor = Self.ringColor.cgColor
            layer.shadowRadius = 6
            layer.shadowOffset = .zero
            layer.shadowOpacity = 0.9
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.35
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: Self.pulseKey)
        }
    }
}
