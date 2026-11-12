import AppKit
import CmdsCore
import QuartzCore

/// The assistant while it waits for its name (#243, Settings › Assistant › Show while waiting): a small orb in a
/// floating, non-activating panel (bottom right above the Dock by default, on every Space) that never takes the
/// keyboard. It breathes slowly while standing by, follows the microphone's level while it hears speech, turns orange
/// when a workspace needs the user and goes dim and hollow while paused. When the assistant is addressed it grows into
/// the HUD (`AssistantHUD`) and comes back when the HUD goes. Clicks outside the circle go through to the window
/// below; a click on it shows the HUD with the last answer, a drag moves it (the place is remembered).
@MainActor
final class AssistantIdleOrb: NSObject {
    /// A click on the orb.
    var onClick: (() -> Void)?
    /// The user dragged it here (its centre).
    var onMoved: ((CGPoint) -> Void)?

    let panel = HUDWindow(contentRect: NSRect(x: 0, y: 0, width: AssistantPresence.Size.small.side,
                                              height: AssistantPresence.Size.small.side),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let orb = AssistantIdleOrbView()
    private(set) var isShown = false
    private(set) var look: AssistantPresence.Look?
    /// Bumped by every show / hide, so a finished fade-out does not hide an orb shown again meanwhile.
    private var generation = 0
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override init() {
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = orb
        orb.onClick = { [weak self] in self?.onClick?() }
        orb.onDragged = { [weak self] delta in
            guard let self else { return }
            self.panel.setFrameOrigin(NSPoint(x: self.panel.frame.minX + delta.x, y: self.panel.frame.minY + delta.y))
        }
        orb.onDropped = { [weak self] in
            guard let self else { return }
            self.onMoved?(CGPoint(x: self.panel.frame.midX, y: self.panel.frame.midY))
        }
    }

    /// Shows the orb (or changes its look) centred on `center`; `fromHUD`: it comes back as the HUD goes.
    func show(look: AssistantPresence.Look, phase: AssistantMachine.Phase, style: AssistantStyle,
              size: AssistantPresence.Size, center: CGPoint, fromHUD: Bool) {
        self.look = look
        orb.update(look: look, style: style, title: AssistantHUD.phaseTitle(phase))
        let side = size.side
        let frame = NSRect(x: (center.x - side / 2).rounded(), y: (center.y - side / 2).rounded(), width: side, height: side)
        if !orb.isDragging, panel.frame != frame { panel.setFrame(frame, display: true) }
        guard !isShown else { return }
        isShown = true
        generation += 1
        panel.orderFrontRegardless()
        guard !reduceMotion else {
            orb.setAppearance(scale: 1, opacity: 1)
            return
        }
        // Shrinks back from the HUD's size: starts larger and transparent, once the HUD has faded.
        orb.setAppearance(scale: 1.6, opacity: 0)
        orb.animate(scale: 1, opacity: 1, duration: AssistantTuning.orbTransition, delay: fromHUD ? AssistantTuning.orbTransition * 0.6 : 0)
    }

    /// `intoHUD`: it grows and fades as the HUD appears.
    func hide(intoHUD: Bool) {
        guard isShown else { return }
        isShown = false
        look = nil
        generation += 1
        guard intoHUD, !reduceMotion else {
            panel.orderOut(nil)
            return
        }
        let number = generation
        orb.animate(scale: 1.8, opacity: 0, duration: AssistantTuning.orbTransition, delay: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + AssistantTuning.orbTransition) { [weak self] in
            guard let self, self.generation == number else { return }
            self.panel.orderOut(nil)
        }
    }

    /// The microphone's level (0…1).
    func level(_ value: Float) {
        guard isShown else { return }
        orb.level(value)
    }

    #if DEBUG
    func debugClick() { onClick?() }

    /// The orb drawn off screen (PNG), as `debug.assistant` `snapshot` returns it.
    func debugSnapshot() -> Data? {
        guard let rep = orb.bitmapImageRepForCachingDisplay(in: orb.bounds) else { return nil }
        orb.cacheDisplay(in: orb.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
    #endif
}

/// The orb itself: a dark disc with a glowing core and a turning broken ring (JARVIS style), or a plain dot (quiet
/// style). Everything inside `content`, whose anchor is its centre, so it grows and shrinks around the middle.
final class AssistantIdleOrbView: NSView {
    var onClick: (() -> Void)?
    var onDragged: ((CGPoint) -> Void)?
    var onDropped: (() -> Void)?
    private(set) var isDragging = false

    private let content = CALayer()
    private let disc = CAShapeLayer()
    private let core = CAGradientLayer()
    private let ring = CAShapeLayer()
    private let dot = CAShapeLayer()
    private var look: AssistantPresence.Look = .standingBy
    private var style: AssistantStyle = .jarvis
    private var configured = false
    private var pressedAt: NSPoint?
    private var lastDrag: NSPoint?
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(content)
        content.addSublayer(disc)
        content.addSublayer(core)
        content.addSublayer(ring)
        content.addSublayer(dot)
        core.type = .radial
        core.startPoint = CGPoint(x: 0.5, y: 0.5)
        core.endPoint = CGPoint(x: 1, y: 1)
        ring.fillColor = nil
        ring.lineCap = .round
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    /// The radius that takes clicks: the disc.
    private var discRadius: CGFloat {
        let side = min(bounds.width, bounds.height)
        return style == .quiet ? side * 0.32 : side / 2 - 1
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = min(bounds.width, bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        content.bounds = bounds
        content.position = center
        let radius = discRadius
        disc.path = CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
        let coreSide = side * 0.46
        core.bounds = CGRect(x: 0, y: 0, width: coreSide, height: coreSide)
        core.position = center
        core.cornerRadius = coreSide / 2
        let ringRadius = side * 0.36
        ring.bounds = CGRect(x: 0, y: 0, width: ringRadius * 2, height: ringRadius * 2)
        ring.position = center
        ring.lineWidth = max(1.5, side / 28)
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: ring.lineWidth, dy: ring.lineWidth), transform: nil)
        // Paused: a whole, still ring.
        ring.lineDashPattern = look == .paused ? nil : [side * 0.5, side * 0.12, side * 0.1, side * 0.12] as [NSNumber]
        let dotSide = side * 0.22
        dot.bounds = CGRect(x: 0, y: 0, width: dotSide, height: dotSide)
        dot.position = center
        dot.path = CGPath(ellipseIn: dot.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        CATransaction.commit()
    }

    func update(look: AssistantPresence.Look, style: AssistantStyle, title: String) {
        setAccessibilityLabel(String(localized: "Assistant: \(title)", comment: "the assistant's waiting orb (VoiceOver); the state, e.g. Standing by"))
        setAccessibilityHelp(String(localized: "Click to show the last answer. Drag to move.", comment: "the assistant's waiting orb (VoiceOver, tooltip)"))
        toolTip = accessibilityHelp()
        guard look != self.look || style != self.style || !configured else { return }
        configured = true
        self.look = look
        self.style = style
        needsLayout = true
        let color: NSColor
        switch look {
        case .standingBy: color = AssistantPalette.cyan
        case .hearing: color = AssistantPalette.cyan.blended(withFraction: 0.35, of: .white) ?? AssistantPalette.cyan
        case .attention: color = AssistantPalette.orange
        case .paused: color = AssistantPalette.dim
        }
        let jarvis = style == .jarvis
        let paused = look == .paused
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.fillColor = AssistantPalette.glass(alpha: jarvis ? 0.78 : 0.5).cgColor
        disc.strokeColor = color.withAlphaComponent(jarvis ? (paused ? 0.45 : 0.55) : 0.3).cgColor
        disc.lineWidth = 1
        // Paused: hollow, only the dim ring.
        core.isHidden = !jarvis || paused
        core.colors = [color.withAlphaComponent(0.95).cgColor, color.withAlphaComponent(0.3).cgColor, NSColor.clear.cgColor]
        core.locations = [0, 0.55, 1]
        ring.isHidden = !jarvis
        ring.strokeColor = color.withAlphaComponent(paused ? 0.9 : 0.85).cgColor
        dot.isHidden = jarvis
        dot.fillColor = paused ? nil : color.withAlphaComponent(0.85).cgColor
        dot.strokeColor = color.withAlphaComponent(paused ? 0.6 : 0.85).cgColor
        dot.lineWidth = 1.2
        core.setAffineTransform(.identity)
        dot.setAffineTransform(.identity)
        CATransaction.commit()
        animateLook()
    }

    private func animateLook() {
        for layer in [core, ring, dot] { layer.removeAllAnimations() }
        guard !reduceMotion, look != .paused else { return }
        if style == .jarvis {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = look == .hearing ? 5 : 14
            spin.repeatCount = .infinity
            ring.add(spin, forKey: "spin")
        }
        // Breathing: slow while standing by, quicker when a workspace needs the user; the level drives it while
        // hearing.
        guard look != .hearing else { return }
        let target = style == .jarvis ? core : dot
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1
        breathe.toValue = style == .jarvis ? 0.45 : 0.55
        breathe.duration = look == .attention ? 1.2 : 2.6
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        target.add(breathe, forKey: "breathe")
        if style == .jarvis {
            let swell = CABasicAnimation(keyPath: "transform.scale")
            swell.fromValue = 1
            swell.toValue = 0.82
            swell.duration = breathe.duration
            swell.autoreverses = true
            swell.repeatCount = .infinity
            swell.timingFunction = breathe.timingFunction
            core.add(swell, forKey: "swell")
        }
    }

    /// The core (or the dot) swells with the input level while hearing; with Reduce Motion the colour says it.
    func level(_ value: Float) {
        guard !reduceMotion, look == .hearing else { return }
        let amount = CGFloat(min(max(value, 0), 1))
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        let scale = style == .jarvis ? 0.85 + amount * 0.45 : 1 + amount * 0.3
        (style == .jarvis ? core : dot).setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
    }

    func setAppearance(scale: CGFloat, opacity: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.removeAnimation(forKey: "transition")
        content.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        content.opacity = opacity
        CATransaction.commit()
    }

    func animate(scale: CGFloat, opacity: Float, duration: TimeInterval, delay: TimeInterval) {
        let from = content.presentation() ?? content
        let fromScale = from.affineTransform().a
        let fromOpacity = from.opacity
        setAppearance(scale: scale, opacity: opacity)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = fromScale
        grow.toValue = scale
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = opacity
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = duration
        group.beginTime = CACurrentMediaTime() + delay
        group.fillMode = .backwards
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        content.add(group, forKey: "transition")
    }

    // MARK: Mouse

    /// Only the disc takes the mouse; around it, clicks go to the window below.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let dx = local.x - bounds.midX, dy = local.y - bounds.midY
        return dx * dx + dy * dy <= discRadius * discRadius ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressedAt = NSEvent.mouseLocation
        lastDrag = pressedAt
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressedAt, let last = lastDrag else { return }
        let now = NSEvent.mouseLocation
        if !isDragging, hypot(now.x - start.x, now.y - start.y) >= AssistantPresence.dragThreshold { isDragging = true }
        guard isDragging else { return }
        onDragged?(CGPoint(x: now.x - last.x, y: now.y - last.y))
        lastDrag = now
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressedAt = nil
            lastDrag = nil
            isDragging = false
        }
        guard pressedAt != nil else { return }
        if isDragging {
            onDropped?()
        } else {
            onClick?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
