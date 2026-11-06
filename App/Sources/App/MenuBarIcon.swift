import AppKit
import CmdsCore

/// Drawings of the menu bar item (#95): the status bar icon with its badges, and the state marks of the workspaces in
/// its menu. `phase` (0..<1) turns the spinners; callers advance it while agents work.
@MainActor
enum MenuBarIcon {
    private static let height: CGFloat = 18
    private static let glyphWidth: CGFloat = 18
    private static let badgeSize: CGFloat = 13
    /// The working badge has a turning arc around it.
    private static let ringSize: CGFloat = 18
    private static let spacing: CGFloat = 2

    /// The cmds glyph, an orange badge with how many workspaces need the user and an accent badge with how many work,
    /// circled by a turning arc. Drawn when shown, so the glyph follows the menu bar's light or dark look.
    static func statusImage(needingUser: Int, working: Int, phase: Double) -> NSImage {
        var width = glyphWidth
        if needingUser > 0 { width += spacing + badgeSize }
        if working > 0 { width += spacing + ringSize }
        return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            if let glyph = NSImage(systemSymbolName: "apple.terminal", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular).applying(.init(paletteColors: [.labelColor]))) {
                let size = glyph.size
                glyph.draw(in: NSRect(x: (glyphWidth - size.width) / 2, y: (height - size.height) / 2,
                                      width: size.width, height: size.height))
            }
            var x = glyphWidth + spacing
            if needingUser > 0 {
                drawBadge(needingUser, color: .systemOrange,
                          in: NSRect(x: x, y: (height - badgeSize) / 2, width: badgeSize, height: badgeSize))
                x += badgeSize + spacing
            }
            if working > 0 {
                let ring = NSRect(x: x, y: (height - ringSize) / 2, width: ringSize, height: ringSize)
                drawBadge(working, color: .controlAccentColor, in: ring.insetBy(dx: (ringSize - badgeSize) / 2, dy: (ringSize - badgeSize) / 2))
                drawArc(in: ring.insetBy(dx: 0.8, dy: 0.8), phase: phase, color: .controlAccentColor, lineWidth: 1.6)
            }
            return true
        }
    }

    /// A workspace's state mark in the menu (16 pt): turning arc while working, orange "!", green check, grey dot.
    /// `highlighted`: the item under the pointer, on the accent-coloured selection, where the marks are drawn in white
    /// (a blue arc would vanish there).
    static func stateImage(_ state: MenuBarSummary.State, phase: Double, highlighted: Bool = false) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let ink: NSColor? = highlighted ? .white : nil
        return NSImage(size: size, flipped: false) { rect in
            switch state {
            case .working:
                let color = ink ?? .controlAccentColor
                color.withAlphaComponent(highlighted ? 0.35 : 0.2).setStroke()
                let track = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
                track.lineWidth = 2
                track.stroke()
                drawArc(in: rect.insetBy(dx: 2, dy: 2), phase: phase, color: color, lineWidth: 2)
            case .needsUser:
                symbol("exclamationmark.circle.fill", colors: highlighted ? [.systemOrange, .white] : [.white, .systemOrange])?
                    .draw(in: rect)
            case .done:
                symbol("checkmark.circle.fill", colors: highlighted ? [.systemGreen, .white] : [.white, .systemGreen])?
                    .draw(in: rect)
            case .idle:
                (ink ?? .secondaryLabelColor).setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.midX - 3, y: rect.midY - 3, width: 6, height: 6)).fill()
            case .stopped:
                (ink ?? .tertiaryLabelColor).setStroke()
                let ring = NSBezierPath(ovalIn: NSRect(x: rect.midX - 3.5, y: rect.midY - 3.5, width: 7, height: 7))
                ring.lineWidth = 1.2
                ring.stroke()
            }
            return true
        }
    }

    private static func symbol(_ name: String, colors: [NSColor]) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular).applying(.init(paletteColors: colors)))
    }

    /// A third of a circle, turned by `phase`.
    private static func drawArc(in rect: NSRect, phase: Double, color: NSColor, lineWidth: CGFloat) {
        let start = 90 - phase * 360
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                      startAngle: start, endAngle: start - 120, clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }

    private static func drawBadge(_ count: Int, color: NSColor, in rect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        let text = count > 9 ? "9+" : "\(count)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: count > 9 ? 7.5 : 9.5, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }
}
