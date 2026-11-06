import AppKit
import CmdsCore

/// Colours of usage meters, shared by the sidebar footer and the menu bar item's ring charts (#95).
extension UsageLevel {
    /// Account limits: green, orange from 80 %, red from 95 %.
    var color: NSColor {
        switch self {
        case .normal: return .systemGreen
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }
}

extension MemoryPressure {
    /// Memory meters: green, yellow on warning, red on critical (also green while unknown).
    var meterColor: NSColor {
        switch self {
        case .critical: return .systemRed
        case .warning: return .systemYellow
        case .normal, .unknown: return .systemGreen
        }
    }
}
