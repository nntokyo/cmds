import AppKit
import CmdsCore

/// A thin bar under a sidebar row: the workspace's progress report (OSC 9;4, `TerminalProgress`). The accent colour
/// fills the percent done; red for a failure; a short segment sliding back and forth while how far is unknown (a Core
/// Animation layer animation: no redraws on the main thread); dimmed while paused. Hidden without a report.
@MainActor
final class ProgressStripView: NSView {
    static let height: CGFloat = 2

    private let track = CALayer()
    private let fill = CALayer()
    private static let slideKey = "cmds.slide"

    var progress: TerminalProgress? {
        didSet { if progress != oldValue { update() } }
    }
    /// On a selected (accent) row: white, as the text.
    var emphasized = false {
        didSet { if emphasized != oldValue { update() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        track.cornerRadius = Self.height / 2
        fill.cornerRadius = Self.height / 2
        isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        update()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update()
    }

    private func update() {
        isHidden = progress == nil
        guard let progress else {
            fill.removeAnimation(forKey: Self.slideKey)
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let tint: NSColor = emphasized ? .white : (progress.state == .error ? .systemRed : .controlAccentColor)
            track.backgroundColor = tint.withAlphaComponent(0.18).cgColor
            fill.backgroundColor = tint.withAlphaComponent(progress.state == .paused ? 0.45 : 1).cgColor
        }
        track.frame = bounds
        if progress.state == .indeterminate {
            let width = max(bounds.width * 0.25, 12)
            fill.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            if fill.animation(forKey: Self.slideKey) == nil || fill.bounds.width != width {
                let slide = CABasicAnimation(keyPath: "position.x")
                slide.fromValue = width / 2
                slide.toValue = max(bounds.width - width / 2, width / 2)
                slide.duration = 1.1
                slide.autoreverses = true
                slide.repeatCount = .infinity
                slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                fill.add(slide, forKey: Self.slideKey)
            }
        } else {
            fill.removeAnimation(forKey: Self.slideKey)
            let done = CGFloat(progress.percent ?? (progress.state == .error ? 100 : 0)) / 100
            fill.frame = CGRect(x: 0, y: 0, width: bounds.width * done, height: bounds.height)
        }
        CATransaction.commit()
        setAccessibilityElement(false)
    }
}
