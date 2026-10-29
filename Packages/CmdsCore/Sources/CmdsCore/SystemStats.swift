import Foundation

/// Machine-wide resource usage sampled by the Mac app every ~2 s.
/// Sent in the socket method `system.stats` and in the sync `state` message (`system`).
public struct SystemStats: Codable, Equatable, Sendable {
    /// Busy share of all cores, 0–100 (100 = every core busy).
    public var cpuPercent: Double
    /// App memory + wired + compressed, as Activity Monitor's "Memory Used".
    public var memoryUsedBytes: UInt64
    /// Installed physical memory.
    public var memoryTotalBytes: UInt64
    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical. nil if unknown.
    public var memoryPressure: Int?

    public init(cpuPercent: Double, memoryUsedBytes: UInt64, memoryTotalBytes: UInt64, memoryPressure: Int? = nil) {
        self.cpuPercent = cpuPercent
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.memoryPressure = memoryPressure
    }

    public var pressure: MemoryPressure { MemoryPressure(level: memoryPressure) }

    /// Used / total, 0...1.
    public var memoryFraction: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return min(1, Double(memoryUsedBytes) / Double(memoryTotalBytes))
    }
}

/// Decoded `SystemStats.memoryPressure`.
public enum MemoryPressure: Equatable, Sendable {
    case normal
    case warning
    case critical
    case unknown

    public init(level: Int?) {
        switch level {
        case 1?: self = .normal
        case 2?: self = .warning
        case 4?: self = .critical
        default: self = .unknown
        }
    }

    public var name: String {
        switch self {
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        case .unknown: return "unknown"
        }
    }
}

/// Per-workspace entry of the `system.stats` result.
public struct WorkspaceStats: Codable, Equatable, Sendable {
    public var id: String
    public var cpuPercent: Double?
    public var memoryBytes: UInt64?

    public init(id: String, cpuPercent: Double? = nil, memoryBytes: UInt64? = nil) {
        self.id = id
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}

/// Result of the socket method `system.stats`.
public struct StatsSnapshot: Codable, Equatable, Sendable {
    /// nil until the app has taken two samples (about a second after launch).
    public var system: SystemStats?
    /// In sidebar order.
    public var workspaces: [WorkspaceStats]

    public init(system: SystemStats?, workspaces: [WorkspaceStats]) {
        self.system = system
        self.workspaces = workspaces
    }
}

/// Compact, width-stable strings for CPU and memory figures (sidebar, CLI, iOS).
/// Byte units are binary (1 GB = 1024³ bytes), as in Activity Monitor.
public enum ResourceFormat {
    /// `0%`, `0.4%`, `9.9%`, `12%`, `104%`: one decimal below 10, whole numbers above.
    public static func percent(_ value: Double) -> String {
        guard value.isFinite, value >= 0.05 else { return "0%" }
        if value < 9.95 { return String(format: "%.1f%%", value) }
        return String(format: "%.0f%%", value)
    }

    /// Whole percent (`0%` … `100%`), for 0–100 gauges.
    public static func wholePercent(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0%" }
        return String(format: "%.0f%%", value)
    }

    /// `512 B`, `4.2 MB`, `45 MB`, `812 MB`, `1.2 GB`, `16.0 GB`. Switches unit at 1000 so at most three digits show.
    public static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var amount = Double(value)
        var unit = 0
        while amount >= 999.5, unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        if unit == 0 { return "\(value) B" }
        let decimals = amount < 9.95 || (unit >= 3 && amount < 99.95)
        return String(format: decimals ? "%.1f %@" : "%.0f %@", amount, units[unit])
    }

    /// `11.2 / 16 GB` (used with one decimal, total without when it is a whole number of GB).
    public static func memory(used: UInt64, total: UInt64) -> String {
        let gib = 1024.0 * 1024 * 1024
        let totalGB = Double(total) / gib
        guard totalGB >= 1 else { return "\(bytes(used)) / \(bytes(total))" }
        let usedText = String(format: "%.1f", Double(used) / gib)
        let totalText = abs(totalGB - totalGB.rounded()) < 0.05 ? String(format: "%.0f", totalGB) : String(format: "%.1f", totalGB)
        return "\(usedText) / \(totalText) GB"
    }

    /// `CPU 12% · 1.2 GB` (missing values as `–`).
    public static func usage(cpuPercent: Double?, memoryBytes: UInt64?) -> String {
        "CPU \(cpuPercent.map(percent) ?? "–") · \(memoryBytes.map(bytes) ?? "–")"
    }
}
