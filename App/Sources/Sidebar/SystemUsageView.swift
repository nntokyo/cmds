import AppKit
import CmdsCore

/// Sidebar footer: machine-wide CPU and memory with thin meters. The memory meter follows the memory
/// pressure (green normal, yellow warning, red critical); the tooltip has the breakdown.
/// `update` only touches labels and meter fills whose value changed.
final class SystemUsageView: NSView {
    private let cpuRow = MeterRow(title: "CPU")
    private let memoryRow = MeterRow(title: "Mem")
    private var tooltipText: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let stack = NSStackView(views: [cpuRow, memoryRow])
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
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("System usage")
        update(sample: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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

    init(title: String) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        titleLabel.textColor = .tertiaryLabelColor
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        meter.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in [titleLabel, meter, valueLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.widthAnchor.constraint(equalToConstant: 26),
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

    func set(value: String, fraction: Double, color: NSColor, valueColor: NSColor? = nil) {
        if valueLabel.stringValue != value { valueLabel.stringValue = value }
        let textColor = valueColor ?? .secondaryLabelColor
        if valueLabel.textColor != textColor { valueLabel.textColor = textColor }
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
