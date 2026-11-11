import AppKit
import CmdsCore
import QuartzCore

/// The HUD's colours per state (#243): cyan while idle or listening, blue while thinking, white-cyan while speaking,
/// amber while an action waits, orange when a workspace needs the user.
enum AssistantPalette {
    static let cyan = NSColor(srgbRed: 0.31, green: 0.85, blue: 1.0, alpha: 1)
    static let blue = NSColor(srgbRed: 0.38, green: 0.55, blue: 1.0, alpha: 1)
    static let amber = NSColor(srgbRed: 1.0, green: 0.72, blue: 0.25, alpha: 1)
    static let orange = NSColor.systemOrange
    static let dim = NSColor(srgbRed: 0.45, green: 0.55, blue: 0.62, alpha: 1)

    static func color(_ phase: AssistantMachine.Phase, attention: Bool) -> NSColor {
        switch phase {
        case .off, .paused: return dim
        case .thinking: return blue
        case .confirming: return amber
        case .speaking: return cyan.blended(withFraction: 0.35, of: .white) ?? cyan
        case .idle, .listening: return attention ? orange : cyan
        }
    }

    static func color(_ state: MenuBarSummary.State?) -> NSColor {
        switch state {
        case .needsUser: return .systemOrange
        case .working: return cyan
        case .done: return .systemGreen
        case .idle, .stopped, nil: return dim
        }
    }
}

/// The animated orb (#243): a glowing core that swells with the voice, and three broken rings turning at speeds that
/// follow the state. Core Animation only; with Reduce Motion nothing turns or pulses, only the colours change.
final class AssistantOrbView: NSView {
    private let core = CAGradientLayer()
    private let rings: [CAShapeLayer] = (0..<3).map { _ in CAShapeLayer() }
    private var phase: AssistantMachine.Phase = .off
    private var attention = false
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(core)
        core.type = .radial
        core.startPoint = CGPoint(x: 0.5, y: 0.5)
        core.endPoint = CGPoint(x: 1, y: 1)
        for (index, ring) in rings.enumerated() {
            ring.fillColor = nil
            ring.lineCap = .round
            ring.lineWidth = [2.5, 1.5, 4][index]
            ring.lineDashPattern = [[40, 14, 8, 14], [3, 6], [70, 40]][index] as [NSNumber]
            layer?.addSublayer(ring)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 112, height: 112) }

    override func layout() {
        super.layout()
        let bounds = self.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = min(bounds.width, bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        core.bounds = CGRect(x: 0, y: 0, width: side * 0.5, height: side * 0.5)
        core.position = center
        core.cornerRadius = side * 0.25
        for (index, ring) in rings.enumerated() {
            let radius = side * [0.46, 0.4, 0.33][index]
            ring.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
            ring.position = center
            ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: ring.lineWidth, dy: ring.lineWidth), transform: nil)
        }
        CATransaction.commit()
    }

    func update(phase: AssistantMachine.Phase, attention: Bool) {
        guard phase != self.phase || attention != self.attention else { return }
        self.phase = phase
        self.attention = attention
        let color = AssistantPalette.color(phase, attention: attention)
        core.colors = [color.withAlphaComponent(0.95).cgColor, color.withAlphaComponent(0.35).cgColor, NSColor.clear.cgColor]
        core.locations = [0, 0.55, 1]
        for (index, ring) in rings.enumerated() {
            ring.strokeColor = color.withAlphaComponent([0.9, 0.55, 0.35][index]).cgColor
            ring.removeAllAnimations()
        }
        core.removeAnimation(forKey: "pulse")
        guard !reduceMotion, phase != .off else { return }
        // Seconds per turn: slow at rest, fast while thinking.
        let period: Double
        switch phase {
        case .thinking: period = 1.6
        case .listening, .confirming: period = 4
        case .speaking: period = 3
        default: period = 9
        }
        for (index, ring) in rings.enumerated() {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = (index % 2 == 0 ? -1.0 : 1.0) * 2 * Double.pi
            spin.duration = period * [1, 1.6, 0.8][index]
            spin.repeatCount = .infinity
            ring.add(spin, forKey: "spin")
        }
        if phase == .confirming || phase == .speaking || phase == .paused {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = phase == .paused ? 0.6 : 0.55
            pulse.duration = phase == .paused ? 2.4 : 0.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            core.add(pulse, forKey: "pulse")
        }
    }

    /// The core swells with the input level (0…1).
    func level(_ value: Float) {
        guard !reduceMotion else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        let scale = 1 + CGFloat(min(max(value, 0), 1)) * 0.35
        core.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
    }
}

/// The input level as a short scrolling waveform (bars, newest on the right).
final class AssistantWaveView: NSView {
    private var levels = [Float](repeating: 0, count: 36)
    var color: NSColor = AssistantPalette.cyan { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 22) }

    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
        needsDisplay = true
    }

    func clear() {
        levels = levels.map { _ in 0 }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = levels.count
        let step = bounds.width / CGFloat(count)
        color.setFill()
        for (index, level) in levels.enumerated() {
            let height = max(2, bounds.height * CGFloat(level))
            let rect = NSRect(x: CGFloat(index) * step + step * 0.2, y: (bounds.height - height) / 2, width: step * 0.6, height: height)
            NSBezierPath(roundedRect: rect, xRadius: step * 0.3, yRadius: step * 0.3).fill()
        }
    }
}

/// One small ring per workspace with an agent (#243), coloured by its state as in the sidebar; the ones that need
/// the user are full circles, working ones a turning arc's still image.
final class AssistantRingsView: NSView {
    struct Ring: Equatable {
        var title: String
        var state: MenuBarSummary.State?
    }

    var rings: [Ring] = [] {
        didSet {
            guard rings != oldValue else { return }
            needsDisplay = true
            invalidateIntrinsicContentSize()
            setAccessibilityLabel(rings.map(\.title).joined(separator: ", "))
        }
    }

    private static let size: CGFloat = 54
    private static let maxRings = 6

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: rings.isEmpty ? 0 : Self.size + 14) }

    override func draw(_ dirtyRect: NSRect) {
        let shown = rings.prefix(Self.maxRings)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
                                                         .foregroundColor: NSColor.white.withAlphaComponent(0.75)]
        for (index, ring) in shown.enumerated() {
            let x = CGFloat(index) * (Self.size + 12)
            let rect = NSRect(x: x + 10, y: 18, width: Self.size - 20, height: Self.size - 20)
            let color = AssistantPalette.color(ring.state)
            let track = NSBezierPath(ovalIn: rect)
            track.lineWidth = 3
            color.withAlphaComponent(0.2).setStroke()
            track.stroke()
            let share: CGFloat
            switch ring.state {
            case .needsUser, .done: share = 1
            case .working: share = 0.66
            default: share = 0.25
            }
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2, startAngle: 90,
                          endAngle: 90 - 360 * share, clockwise: true)
            arc.lineWidth = 3
            arc.lineCapStyle = .round
            color.setStroke()
            arc.stroke()
            let title = ring.title.count > 9 ? String(ring.title.prefix(8)) + "…" : ring.title
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(at: NSPoint(x: x + (Self.size - size.width) / 2, y: 2), withAttributes: attributes)
        }
    }
}
