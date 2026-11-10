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

    private(set) var content: NSView
    /// Covers the content (SSH panes: Disconnected / Reconnect); below the ring.
    private(set) var overlay: NSView?

    /// The grip that moves the pane by drag (#218); shown while the mouse is near the top edge.
    let dragHandle: PaneDragHandleView
    /// Height of the strip along the top edge where the grip appears.
    private static let handleZoneHeight: CGFloat = 22
    /// The tracking area of that strip; replaced (only it) when the bounds change.
    private var handleZone: NSTrackingArea?

    init(paneID: String, content: NSView) {
        self.paneID = paneID
        self.content = content
        dragHandle = PaneDragHandleView(paneID: paneID)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        wantsLayer = true
        pin(content)
        dragHandle.isHidden = true
        let size = PaneDragHandleView.size
        dragHandle.frame = NSRect(x: (bounds.width - size.width) / 2, y: bounds.height - size.height,
                                  width: size.width, height: size.height)
        dragHandle.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]  // top centre
        addSubview(dragHandle)
        ring.frame = bounds
        ring.autoresizingMask = [.width, .height]
        addSubview(ring)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Swaps the hosted view (an SSH pane gets a new terminal surface on reconnect).
    func setContent(_ view: NSView) {
        guard view !== content else { return }
        content.removeFromSuperview()
        content = view
        pin(view, below: overlay ?? banner ?? ring)
    }

    func setOverlay(_ view: NSView?) {
        guard view !== overlay else { return }
        overlay?.removeFromSuperview()
        overlay = view
        if let view { pin(view, below: banner ?? ring) }
    }

    /// Slim bar along the top edge (agent session resume offer); above content and overlay, below the ring.
    private(set) var banner: NSView?

    func setBanner(_ view: NSView?) {
        guard view !== banner else { return }
        banner?.removeFromSuperview()
        banner = view
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view, positioned: .below, relativeTo: ring)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            view.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            view.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        ])
    }

    /// The find bar (⌘F, `TerminalFind`) in the top-right corner, above everything but the ring.
    private(set) var findBar: NSView?

    func setFindBar(_ view: NSView?) {
        guard view !== findBar else { return }
        findBar?.removeFromSuperview()
        findBar = view
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view, positioned: .below, relativeTo: ring)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            view.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        ])
    }

    /// Outline of the find bar's selected hit (frame set by `TerminalFind`), right above the content.
    private(set) var findMarker: NSView?

    func setFindMarker(_ view: NSView?) {
        guard view !== findMarker else { return }
        findMarker?.removeFromSuperview()
        findMarker = view
        guard let view else { return }
        addSubview(view, positioned: .above, relativeTo: content)
    }

    private func pin(_ view: NSView, below sibling: NSView? = nil) {
        view.translatesAutoresizingMaskIntoConstraints = false
        if let sibling, sibling.superview === self {
            addSubview(view, positioned: .below, relativeTo: sibling)
        } else {
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let handleZone { removeTrackingArea(handleZone) }
        let zone = NSRect(x: 0, y: bounds.height - Self.handleZoneHeight, width: bounds.width, height: Self.handleZoneHeight)
        let area = NSTrackingArea(rect: zone, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        handleZone = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard dragHandle.isHidden else { return }
        // Above banners and the find bar that came later; the ring stays on top.
        addSubview(dragHandle, positioned: .below, relativeTo: ring)
        dragHandle.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        if !dragHandle.isDragging { dragHandle.isHidden = true }
    }

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
