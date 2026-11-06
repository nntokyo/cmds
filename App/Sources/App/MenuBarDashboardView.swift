import AppKit
import CmdsCore

/// Top of the menu bar item's menu (#95): ring charts instead of text. A row for the Mac (CPU, memory) and one per
/// agent with account limits (5-hour, 7-day, …), each ring filled by its share, the percentage inside and the window
/// and reset time under it. Colours as in the sidebar footer: limits green, orange from 80 %, red from 95 %; memory by
/// memory pressure.
@MainActor
final class MenuBarDashboardView: NSView {
    struct Gauge: Equatable {
        var label: String
        var fraction: Double
        var value: String
        var color: NSColor
        /// Reset time of a limit window; nil for CPU and memory.
        var caption: String?
    }

    struct Row: Equatable {
        var title: String
        var gauges: [Gauge]
        /// Figures older than an hour (no agent ran since) are drawn faded.
        var stale = false
    }

    static let width: CGFloat = 290
    private static let insets = NSEdgeInsets(top: 8, left: 14, bottom: 6, right: 14)
    private static let titleWidth: CGFloat = 56
    private static let cellWidth: CGFloat = 74
    private static let ring: CGFloat = 44
    private static let lineWidth: CGFloat = 5
    private static let rowHeight: CGFloat = 82

    private var rows: [Row] = []

    override var isFlipped: Bool { true }

    /// `showsMachine`: the CPU and memory row (Settings › Menu Bar › Menu, #105).
    func update(sample: SystemSample?, agentLimits: [AgentLimits], showsMachine: Bool = true, now: Date = Date()) {
        var rows = showsMachine ? [Row(title: "Mac", gauges: Self.machineGauges(sample))] : []
        for limits in agentLimits {
            let gauges = limits.ordered.map { limit in
                let level = UsageLevel(percent: limit.usedPercent)
                return Gauge(label: limit.id == UsageLimit.spend ? "$" : AgentFormat.limitLabel(limit, strings: .localized),
                             fraction: limit.usedPercent / 100, value: AgentFormat.percent(limit.usedPercent),
                             color: level.color,
                             caption: limit.resetsAt.map { Self.shortReset($0, now: now) })
            }
            rows.append(Row(title: limits.agent.displayName, gauges: gauges,
                            stale: now.timeIntervalSince(limits.updatedAt) > 3600))
        }
        guard rows != self.rows else { return }
        self.rows = rows
        let height = Self.insets.top + CGFloat(rows.count) * Self.rowHeight + Self.insets.bottom
        setFrameSize(NSSize(width: Self.width, height: height))
        setAccessibilityLabel(rows.map { row in
            row.title + " " + row.gauges.map { "\($0.label) \($0.value)" }.joined(separator: ", ")
        }.joined(separator: "; "))
        needsDisplay = true
    }

    /// Within a day, how long until the reset (`in 2h10m`), which needs no clock arithmetic; later, the day and time
    /// (`Fri 09:00`) (#105).
    static func shortReset(_ date: Date, now: Date) -> String {
        let interval = date.timeIntervalSince(now)
        if interval > 0, interval < 86400 {
            let duration = AgentFormat.duration(milliseconds: Int(interval * 1000), strings: .localized)
            return String(localized: "in \(duration)", comment: "menu bar ring: time until an account limit resets")
        }
        let text = AgentFormat.resetTime(date, now: now, strings: .localized)
        return text.components(separatedBy: " (").first ?? text
    }

    private static func machineGauges(_ sample: SystemSample?) -> [Gauge] {
        guard let stats = sample?.stats else {
            return [Gauge(label: String(localized: "CPU", comment: "sidebar meter title"), fraction: 0, value: "–",
                          color: .controlAccentColor),
                    Gauge(label: String(localized: "Mem", comment: "sidebar meter title (memory)"), fraction: 0, value: "–",
                          color: .systemGreen)]
        }
        return [
            Gauge(label: String(localized: "CPU", comment: "sidebar meter title"), fraction: stats.cpuPercent / 100,
                  value: ResourceFormat.wholePercent(stats.cpuPercent), color: .controlAccentColor),
            Gauge(label: String(localized: "Mem", comment: "sidebar meter title (memory)"), fraction: stats.memoryFraction,
                  value: ResourceFormat.wholePercent(stats.memoryFraction * 100), color: stats.pressure.meterColor,
                  caption: ByteCountFormatter.string(fromByteCount: Int64(stats.memoryUsedBytes), countStyle: .memory)),
        ]
    }

    override func draw(_ dirtyRect: NSRect) {
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for (index, row) in rows.enumerated() {
            let top = Self.insets.top + CGFloat(index) * Self.rowHeight
            let alpha: CGFloat = row.stale ? 0.5 : 1
            let titleSize = row.title.size(withAttributes: titleAttributes)
            row.title.draw(at: NSPoint(x: Self.insets.left, y: top + Self.ring / 2 - titleSize.height / 2),
                           withAttributes: titleAttributes)
            for (column, gauge) in row.gauges.enumerated() {
                let x = Self.insets.left + Self.titleWidth + CGFloat(column) * Self.cellWidth
                guard x + Self.cellWidth <= Self.width else { break }
                drawGauge(gauge, cell: NSRect(x: x, y: top, width: Self.cellWidth, height: Self.rowHeight), alpha: alpha)
            }
        }
    }

    private func drawGauge(_ gauge: Gauge, cell: NSRect, alpha: CGFloat) {
        let ring = NSRect(x: cell.midX - Self.ring / 2, y: cell.minY, width: Self.ring, height: Self.ring)
            .insetBy(dx: Self.lineWidth / 2, dy: Self.lineWidth / 2)
        let center = NSPoint(x: ring.midX, y: ring.midY)
        let radius = ring.width / 2

        let track = NSBezierPath(ovalIn: ring)
        track.lineWidth = Self.lineWidth
        NSColor.tertiaryLabelColor.withAlphaComponent(0.25 * alpha).setStroke()
        track.stroke()

        let fraction = min(max(gauge.fraction, 0), 1)
        if fraction > 0 {
            // Clockwise from 12 o'clock (flipped view: angles grow clockwise).
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: -90, endAngle: -90 + fraction * 360, clockwise: false)
            arc.lineWidth = Self.lineWidth
            arc.lineCapStyle = .round
            gauge.color.withAlphaComponent(alpha).setStroke()
            arc.stroke()
        }

        Self.drawCentered(gauge.value, at: center, size: gauge.value.count > 3 ? 9.5 : 10.5, weight: .semibold,
                          color: NSColor.labelColor.withAlphaComponent(alpha))
        Self.drawCentered(gauge.label, at: NSPoint(x: cell.midX, y: ring.maxY + Self.lineWidth / 2 + 9), size: 10,
                          weight: .medium, color: NSColor.secondaryLabelColor.withAlphaComponent(alpha))
        if let caption = gauge.caption {
            Self.drawCentered(caption, at: NSPoint(x: cell.midX, y: ring.maxY + Self.lineWidth / 2 + 22), size: 9,
                              weight: .regular, color: NSColor.tertiaryLabelColor.withAlphaComponent(alpha), maxWidth: cell.width - 2)
        }
    }

    private static func drawCentered(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight,
                                     color: NSColor, maxWidth: CGFloat? = nil) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight), .foregroundColor: color,
            .paragraphStyle: style,
        ]
        let measured = text.size(withAttributes: attributes)
        let width = min(measured.width, maxWidth ?? measured.width)
        text.draw(in: NSRect(x: point.x - width / 2, y: point.y - measured.height / 2, width: width, height: measured.height),
                  withAttributes: attributes)
    }
}
