import AppKit
import CmdsCore

/// Sidebar footer: machine-wide CPU and memory with thin meters. The memory meter follows the memory
/// pressure (green normal, yellow warning, red critical); the tooltip has the breakdown.
/// `update` only touches labels and meter fills whose value changed.
final class SystemUsageView: NSView {
    private let cpuRow = MeterRow(title: "CPU")
    private let memoryRow = MeterRow(title: "Mem")
    private var tooltipText: String?
    /// Account limits of the coding agents, above CPU/memory; hidden while none is known.
    private let agentStack = NSStackView()
    private var agentRows: [AgentKind: AgentLimitsRow] = [:]
    private let stack = NSStackView()

    /// Title column: "CPU"/"Mem" alone, wide enough for "Claude"/"Codex" when agent rows show (meters stay aligned).
    static let titleWidth: CGFloat = 26
    static let agentTitleWidth: CGFloat = 34

    override init(frame: NSRect) {
        super.init(frame: frame)
        agentStack.orientation = .vertical
        agentStack.alignment = .leading
        agentStack.spacing = 5
        agentStack.isHidden = true
        stack.setViews([agentStack, cpuRow, memoryRow], in: .top)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            cpuRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            memoryRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // Same value column width in both rows, so the two meters line up and have equal length.
            cpuRow.valueWidthAnchor.constraint(equalTo: memoryRow.valueWidthAnchor),
            agentStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("System usage")
        update(sample: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// One row per agent kind with active limits (`Claude 5h ▰▱ 40%  7d ▰▱ 12%`). Rows are added/removed only when an
    /// agent's limits appear or all of its windows reset; otherwise only values and fills change.
    func update(agentLimits: [AgentLimits], now: Date = Date()) {
        let kinds = agentLimits.map(\.agent)
        for (kind, row) in agentRows where !kinds.contains(kind) {
            agentStack.removeView(row)
            agentRows[kind] = nil
        }
        for (index, limits) in agentLimits.enumerated() {
            let row: AgentLimitsRow
            if let existing = agentRows[limits.agent] {
                row = existing
            } else {
                row = AgentLimitsRow(title: limits.agent.displayName)
                agentRows[limits.agent] = row
                agentStack.insertView(row, at: min(index, agentStack.views.count), in: .top)
                row.widthAnchor.constraint(equalTo: agentStack.widthAnchor).isActive = true
            }
            row.update(limits, now: now)
        }
        agentStack.isHidden = agentLimits.isEmpty
        let width = agentLimits.isEmpty ? Self.titleWidth : Self.agentTitleWidth
        cpuRow.titleWidth = width
        memoryRow.titleWidth = width
    }

    func update(sample: SystemSample?) {
        guard let sample else {
            cpuRow.set(value: "–", fraction: 0, color: Self.cpuColor)
            memoryRow.set(value: "–", fraction: 0, color: Self.color(for: .unknown))
            setTooltip("Measuring CPU and memory…")
            return
        }
        let stats = sample.stats
        let pressure = stats.pressure
        cpuRow.set(value: ResourceFormat.wholePercent(stats.cpuPercent), fraction: stats.cpuPercent / 100,
                   color: Self.cpuColor)
        memoryRow.set(value: ResourceFormat.memory(used: stats.memoryUsedBytes, total: stats.memoryTotalBytes),
                      fraction: stats.memoryFraction, color: Self.color(for: pressure),
                      valueColor: pressure == .warning || pressure == .critical ? Self.color(for: pressure) : nil)
        setAccessibilityValue("CPU \(ResourceFormat.wholePercent(stats.cpuPercent)), memory "
                              + "\(ResourceFormat.memory(used: stats.memoryUsedBytes, total: stats.memoryTotalBytes)), "
                              + "pressure \(pressure.name)")
        setTooltip(Self.tooltip(for: sample))
    }

    private func setTooltip(_ text: String) {
        guard text != tooltipText else { return }
        tooltipText = text
        toolTip = text
        cpuRow.toolTip = text
        memoryRow.toolTip = text
    }

    private static let cpuColor = NSColor.controlAccentColor

    private static func color(for pressure: MemoryPressure) -> NSColor {
        switch pressure {
        case .normal: return .systemGreen
        case .warning: return .systemYellow
        case .critical: return .systemRed
        case .unknown: return .secondaryLabelColor
        }
    }

    private static func tooltip(for sample: SystemSample) -> String {
        let stats = sample.stats
        let bytes = ResourceFormat.bytes
        var lines = [
            "CPU \(String(format: "%.1f", stats.cpuPercent))% of all \(sample.cpuCount) cores",
            "Memory used \(bytes(stats.memoryUsedBytes)) of \(bytes(stats.memoryTotalBytes))",
            "   App \(bytes(sample.appMemoryBytes)) · Wired \(bytes(sample.wiredBytes)) · Compressed \(bytes(sample.compressedBytes))",
        ]
        if let used = sample.swapUsedBytes, let total = sample.swapTotalBytes, total > 0 {
            lines.append("Swap used \(bytes(used)) of \(bytes(total))")
        }
        lines.append("Memory pressure: \(stats.pressure.name)")
        return lines.joined(separator: "\n")
    }
}

/// `CPU ▰▰▰▱▱▱  23%`: title, flexible meter, value.
private final class MeterRow: NSView {
    private let titleLabel: NSTextField
    private let meter = MeterView()
    private let valueLabel = NSTextField(labelWithString: "")
    private var titleWidthConstraint: NSLayoutConstraint!

    var titleWidth: CGFloat {
        get { titleWidthConstraint.constant }
        set { if titleWidthConstraint.constant != newValue { titleWidthConstraint.constant = newValue } }
    }

    init(title: String) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        titleWidthConstraint = titleLabel.widthAnchor.constraint(equalToConstant: SystemUsageView.titleWidth)
        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        titleLabel.textColor = .tertiaryLabelColor
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        // Hugging below required lets the shared value-column width stretch the narrower label.
        valueLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        meter.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in [titleLabel, meter, valueLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleWidthConstraint,
            titleLabel.firstBaselineAnchor.constraint(equalTo: valueLabel.firstBaselineAnchor),
            meter.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 4),
            meter.trailingAnchor.constraint(equalTo: valueLabel.leadingAnchor, constant: -8),
            meter.centerYAnchor.constraint(equalTo: valueLabel.centerYAnchor),
            meter.heightAnchor.constraint(equalToConstant: 4),
            meter.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.topAnchor.constraint(equalTo: topAnchor),
            valueLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var valueWidthAnchor: NSLayoutDimension { valueLabel.widthAnchor }

    func set(value: String, fraction: Double, color: NSColor, valueColor: NSColor? = nil) {
        if valueLabel.stringValue != value { valueLabel.stringValue = value }
        let textColor = valueColor ?? .secondaryLabelColor
        if valueLabel.textColor != textColor { valueLabel.textColor = textColor }
        meter.set(fraction: fraction, color: color)
    }
}

/// `Claude  5h ▰▰▱ 40%   7d ▰▱▱ 12%`: the agent's 5-hour and 7-day windows (or its first two); further limits
/// (spend) continue on lines below. Meters: green, orange from 80 %, red from 95 %. Tooltip: reset times.
private final class AgentLimitsRow: NSView {
    private let titleLabel: NSTextField
    private let lines = NSStackView()
    private var segments: [LimitSegment] = []
    private var tooltipText: String?

    init(title: String) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        titleLabel.textColor = .tertiaryLabelColor
        titleLabel.lineBreakMode = .byClipping
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 4
        for view in [titleLabel, lines] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.widthAnchor.constraint(equalToConstant: SystemUsageView.agentTitleWidth),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            lines.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 4),
            lines.trailingAnchor.constraint(equalTo: trailingAnchor),
            lines.topAnchor.constraint(equalTo: topAnchor),
            lines.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(_ limits: AgentLimits, now: Date) {
        let windows = limits.ordered
        if windows.count != segments.count { rebuild(count: windows.count) }
        for (segment, limit) in zip(segments, windows) {
            let level = UsageLevel(percent: limit.usedPercent)
            segment.set(label: AgentFormat.limitLabel(limit), value: limit.id == UsageLimit.spend ? AgentFormat.limitValue(limit)
                        : AgentFormat.percent(limit.usedPercent), fraction: limit.usedPercent / 100, level: level)
        }
        // Old figures (no agent ran for a while) are dimmed.
        let old = now.timeIntervalSince(limits.updatedAt) > 3600
        alphaValue = old ? 0.6 : 1
        var tooltip = ["\(limits.agent.displayName) account limits" + (limits.plan.map { " (\($0))" } ?? "")]
        tooltip += AgentFormat.limitLines(windows, now: now)
        tooltip.append("Updated \(AgentFormat.age(limits.updatedAt, now: now))")
        let text = tooltip.joined(separator: "\n")
        if text != tooltipText {
            tooltipText = text
            toolTip = text
            setAccessibilityLabel(text)
        }
    }

    /// Two segments per line, equal widths.
    private func rebuild(count: Int) {
        lines.views.forEach { lines.removeView($0) }
        segments = (0..<count).map { _ in LimitSegment() }
        var index = 0
        while index < count {
            let pair: [NSView] = Array(segments[index..<min(index + 2, count)])
            // A lone segment gets an empty partner so it is as wide as the others.
            let line = NSStackView(views: pair.count == 2 ? pair : pair + [NSView()])
            line.orientation = .horizontal
            line.spacing = 8
            line.distribution = .fillEqually
            lines.addView(line, in: .top)
            line.widthAnchor.constraint(equalTo: lines.widthAnchor).isActive = true
            index += 2
        }
    }
}

/// `5h ▰▰▱ 40%`.
private final class LimitSegment: NSView {
    private let label = NSTextField(labelWithString: "")
    private let meter = MeterView()
    private let value = NSTextField(labelWithString: "")
    private var level: UsageLevel?

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .tertiaryLabelColor
        label.setContentHuggingPriority(.required, for: .horizontal)
        value.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        value.alignment = .right
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [label, meter, value] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // Fixed value column ("100%"), so changing digits never move the meter.
        let valueWidth = ("100%" as NSString).size(withAttributes: [.font: value.font!]).width.rounded(.up) + 1
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.firstBaselineAnchor.constraint(equalTo: value.firstBaselineAnchor),
            meter.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 3),
            meter.trailingAnchor.constraint(equalTo: value.leadingAnchor, constant: -4),
            meter.centerYAnchor.constraint(equalTo: value.centerYAnchor),
            meter.heightAnchor.constraint(equalToConstant: 4),
            meter.widthAnchor.constraint(greaterThanOrEqualToConstant: 8),
            value.widthAnchor.constraint(greaterThanOrEqualToConstant: valueWidth),
            value.trailingAnchor.constraint(equalTo: trailingAnchor),
            value.topAnchor.constraint(equalTo: topAnchor),
            value.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(label text: String, value newValue: String, fraction: Double, level newLevel: UsageLevel) {
        if label.stringValue != text { label.stringValue = text }
        if value.stringValue != newValue { value.stringValue = newValue }
        let color: NSColor
        switch newLevel {
        case .normal: color = .systemGreen
        case .warning: color = .systemOrange
        case .critical: color = .systemRed
        }
        if level != newLevel {
            level = newLevel
            value.textColor = newLevel == .normal ? .secondaryLabelColor : color
        }
        meter.set(fraction: fraction, color: color)
    }
}

/// Rounded track with a proportional fill (layer-backed; the fill eases to new values).
private final class MeterView: NSView {
    private let fill = CALayer()
    private var fraction: Double = 0
    private var color: NSColor = .secondaryLabelColor

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 2
        layer?.masksToBounds = true
        fill.cornerRadius = 2
        fill.anchorPoint = .zero
        layer?.addSublayer(fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            fill.backgroundColor = color.withAlphaComponent(0.85).cgColor
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true) // resizing the sidebar must not animate
        fill.frame = fillFrame
        CATransaction.commit()
    }

    func set(fraction newValue: Double, color newColor: NSColor) {
        let clamped = newValue.isFinite ? min(max(newValue, 0), 1) : 0
        if newColor != color {
            color = newColor
            needsDisplay = true
        }
        guard abs(clamped - fraction) > 0.001 else { return }
        fraction = clamped
        fill.frame = fillFrame // implicit animation eases the change
    }

    private var fillFrame: CGRect {
        CGRect(x: 0, y: 0, width: (bounds.width * fraction).rounded(), height: bounds.height)
    }
}
