import CmdsCore
import SwiftUI

/// `CPU 12% · 1.2 GB` for one workspace (CPU as in Activity Monitor: 100% = one core).
struct WorkspaceUsageLine: View {
    let cpuPercent: Double?
    let memoryBytes: UInt64?

    var body: some View {
        let cpu = cpuPercent.map(ResourceFormat.percent) ?? "–"
        let memory = memoryBytes.map(ResourceFormat.bytes) ?? "–"
        HStack(spacing: 4) {
            Text("CPU").foregroundStyle(.tertiary)
            // Reserve the width of "100%" so the memory figure does not shift as CPU digits change.
            Text(verbatim: "100%").hidden().overlay(alignment: .leading) {
                Text(cpu).foregroundStyle((cpuPercent ?? 0) > 100 ? Color.orange : Color.secondary)
            }
            Text(verbatim: "·").foregroundStyle(.tertiary)
            Text(memory).foregroundStyle(.secondary)
        }
        .font(.caption2.monospacedDigit())
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU \(cpu), memory \(memory)")
    }
}

/// One agent's account limits: `Claude  5h ━━━ 40%  7d ━ 12%` (meters orange from 80 %, red from 95 %).
struct AgentLimitsBar: View {
    let limits: AgentLimits

    var body: some View {
        let windows = Array(limits.ordered.prefix(3))
        HStack(alignment: .bottom, spacing: 12) {
            Text(limits.agent.displayName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            ForEach(windows) { limit in
                let level = UsageLevel(percent: limit.usedPercent)
                UsageGauge(title: limit.id == UsageLimit.spend ? "$" : AgentFormat.limitLabel(limit, strings: .localized),
                           value: limit.id == UsageLimit.spend ? AgentFormat.limitValue(limit) : AgentFormat.percent(limit.usedPercent),
                           fraction: limit.usedPercent / 100, tint: level.color,
                           valueTint: level == .normal ? nil : level.color)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(limits.agent.displayName) limits: \(AgentFormat.limitLines(windows, strings: .localized).joined(separator: ", "))"))
    }
}

/// The workspace's agent pane: `Claude Opus 4.5 · ctx 53% · $117.99 · 5h 40%`.
struct AgentSummaryLine: View {
    let usage: AgentUsage
    let limits: [UsageLimit]?

    var body: some View {
        let parts = AgentFormat.summaryParts(usage, limits: limits, strings: .localized)
        parts.reduce(Text(verbatim: "")) { text, part in
            var piece = Text(part.text)
            switch part.style {
            case .name: piece = piece.fontWeight(.medium).foregroundColor(.primary.opacity(0.85))
            case .label, .separator: piece = piece.foregroundColor(Color(uiColor: .tertiaryLabel))
            case .value: piece = piece.foregroundColor(part.level == .normal ? .secondary : part.level.color)
            }
            return text + piece
        }
        .font(.caption2.monospacedDigit())
        .lineLimit(1)
        .opacity(usage.isStale ? 0.6 : 1)
        .accessibilityLabel(usage.isStale ? String(localized: "\(AgentFormat.summary(usage, limits: limits, strings: .localized)), idle")
                                              : AgentFormat.summary(usage, limits: limits, strings: .localized))
    }
}

extension UsageLevel {
    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

/// Mac-wide CPU and memory with thin meters; the memory meter follows the memory pressure.
struct SystemStatsBar: View {
    let stats: SystemStats

    var body: some View {
        let memory = ResourceFormat.memory(used: stats.memoryUsedBytes, total: stats.memoryTotalBytes)
        let pressure = stats.pressure
        HStack(spacing: 16) {
            UsageGauge(title: "CPU", value: ResourceFormat.wholePercent(stats.cpuPercent),
                       fraction: stats.cpuPercent / 100, tint: .accentColor)
            UsageGauge(title: pressure == .normal || pressure == .unknown ? String(localized: "Mem")
                                                                       : String(localized: "Mem · \(pressure.localizedName)"),
                       value: memory, fraction: stats.memoryFraction, tint: pressureColor,
                       valueTint: pressure == .warning || pressure == .critical ? pressureColor : nil)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mac CPU \(ResourceFormat.wholePercent(stats.cpuPercent)), memory \(memory), pressure \(pressure.localizedName)")
    }

    private var pressureColor: Color {
        switch stats.pressure {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        case .unknown: return .secondary
        }
    }
}

private struct UsageGauge: View {
    let title: String
    let value: String
    let fraction: Double
    let tint: Color
    var valueTint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(value).font(.caption2.monospacedDigit()).foregroundStyle(valueTint ?? .primary)
            }
            UsageMeter(fraction: fraction, tint: tint)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Thin capsule track with a proportional fill.
private struct UsageMeter: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0
            Capsule()
                .fill(Color.secondary.opacity(0.2))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint.opacity(0.85))
                        .frame(width: geo.size.width * clamped)
                }
                .animation(.easeOut(duration: 0.4), value: clamped)
        }
        .frame(height: 4)
    }
}
