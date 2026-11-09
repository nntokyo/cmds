import Foundation

// Per-process breakdown of what runs in cmds terminals (#193): the socket methods `system.processes` and
// `system.kill_process`, `cmds top` / `cmds kill`, the sidebar's leftover row and the MCP tools system_stats and
// list_processes. The Mac app's scanner (MetadataMonitor.swift) reads the processes; the rules live here.

/// One process started from a cmds terminal, as read by the app's process scan (`ProcessScanner`).
public struct ScannedProcess: Equatable, Sendable {
    public var pid: Int32
    /// Start time in microseconds since 1970 (`proc_bsdinfo`). With `pid` it identifies the process (pids are reused).
    public var startMicroseconds: UInt64
    public var name: String
    /// Executable and arguments, cut (`ProcessEntry.maxCommandLength`); nil when macOS does not show them.
    public var command: String?
    public var workspace: String
    /// `CMDS_PANE_ID`, else the pane whose terminal it ran in; nil when unknown.
    public var pane: String?
    /// Physical footprint.
    public var memoryBytes: UInt64
    /// 100 = one core busy; nil before the second scan.
    public var cpuPercent: Double?

    public init(pid: Int32, startMicroseconds: UInt64, name: String, command: String? = nil, workspace: String,
                pane: String? = nil, memoryBytes: UInt64 = 0, cpuPercent: Double? = nil) {
        self.pid = pid
        self.startMicroseconds = startMicroseconds
        self.name = name
        self.command = command
        self.workspace = workspace
        self.pane = pane
        self.memoryBytes = memoryBytes
        self.cpuPercent = cpuPercent
    }

    public var started: Date { Date(timeIntervalSince1970: Double(startMicroseconds) / 1_000_000) }

    /// Started from a pane or workspace that no longer exists (closed, or from before the app started).
    /// - Parameter appStarted: the app's launch, µs since 1970. Every process of a live pane started after it, so an
    ///   older one carries the ids of an earlier run (ids repeat across launches).
    public func isLeftover(livePanes: Set<String>, liveWorkspaces: Set<String>, appStarted: UInt64) -> Bool {
        if startMicroseconds < appStarted { return true }
        guard liveWorkspaces.contains(workspace) else { return true }
        if let pane, !livePanes.contains(pane) { return true }
        return false
    }
}

/// One entry of the `system.processes` result.
public struct ProcessEntry: Codable, Equatable, Sendable {
    public static let maxCommandLength = 300

    public var pid: Int32
    /// Short name (as Activity Monitor shows it).
    public var name: String
    /// Executable and arguments, cut at `maxCommandLength` characters. Omitted when macOS does not show them.
    public var command: String?
    /// Pane it was started in, when known.
    public var pane: String?
    public var workspace: String
    /// Physical footprint ("Memory" in Activity Monitor).
    public var memoryBytes: UInt64
    /// 100 = one core busy. Omitted until the app has two readings.
    public var cpuPercent: Double?
    /// Start time, seconds since 1970 (microsecond precision): with `pid` it identifies the process for
    /// `system.kill_process`.
    public var started: Double
    /// Its pane or workspace no longer exists (closed, or from before the app started). Omitted when false.
    public var leftover: Bool?

    public init(pid: Int32, name: String, command: String? = nil, pane: String? = nil, workspace: String,
                memoryBytes: UInt64, cpuPercent: Double? = nil, started: Double, leftover: Bool? = nil) {
        self.pid = pid
        self.name = name
        self.command = command
        self.pane = pane
        self.workspace = workspace
        self.memoryBytes = memoryBytes
        self.cpuPercent = cpuPercent
        self.started = started
        self.leftover = leftover
    }

    public var isLeftover: Bool { leftover == true }

    /// The command with the executable's folder dropped (`Python -m http.server 8000`), cut at `maxLength`; the name
    /// when there is no command. For tooltips and other narrow places.
    public func shortCommand(maxLength: Int = 48) -> String {
        guard let command, !command.isEmpty else { return name }
        var words = command.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        if words[0].contains("/") { words[0] = (words[0] as NSString).lastPathComponent }
        let text = words.joined(separator: " ")
        return text.count > maxLength ? String(text.prefix(maxLength - 1)) + "…" : text
    }
}

/// Result of `system.processes`.
public struct ProcessList: Codable, Equatable, Sendable {
    /// Heaviest (memory footprint) first, after the request's filters and limit.
    public var processes: [ProcessEntry]
    /// Processes matching the filters before the limit.
    public var total: Int
    /// Memory of all of them (before the limit).
    public var totalMemoryBytes: UInt64

    public init(processes: [ProcessEntry], total: Int, totalMemoryBytes: UInt64) {
        self.processes = processes
        self.total = total
        self.totalMemoryBytes = totalMemoryBytes
    }

    /// Builds the list from a scan: filters, marks leftovers, sorts by memory (then pid) and cuts at the limit.
    public static func build(_ scanned: [ScannedProcess], request: ProcessListRequest, livePanes: Set<String>,
                             liveWorkspaces: Set<String>, appStarted: UInt64) -> ProcessList {
        var entries: [ProcessEntry] = []
        for process in scanned {
            let leftover = process.isLeftover(livePanes: livePanes, liveWorkspaces: liveWorkspaces, appStarted: appStarted)
            if let workspace = request.workspace, process.workspace != workspace { continue }
            if let pane = request.pane, process.pane != pane { continue }
            if request.leftover, !leftover { continue }
            var command = process.command
            if let text = command, text.count > ProcessEntry.maxCommandLength {
                command = String(text.prefix(ProcessEntry.maxCommandLength - 1)) + "…"
            }
            entries.append(ProcessEntry(pid: process.pid, name: process.name, command: command, pane: process.pane,
                                        workspace: process.workspace, memoryBytes: process.memoryBytes,
                                        cpuPercent: process.cpuPercent.map { ($0 * 10).rounded() / 10 },
                                        started: Double(process.startMicroseconds) / 1_000_000,
                                        leftover: leftover ? true : nil))
        }
        entries.sort { $0.memoryBytes != $1.memoryBytes ? $0.memoryBytes > $1.memoryBytes : $0.pid < $1.pid }
        let memory = entries.reduce(UInt64(0)) { $0 &+ $1.memoryBytes }
        return ProcessList(processes: Array(entries.prefix(request.limit)), total: entries.count, totalMemoryBytes: memory)
    }
}

/// Params of `system.processes`: `{limit?, workspace?, pane?, leftover?}`.
public struct ProcessListRequest: Equatable, Sendable {
    public static let defaultLimit = 20
    public static let maxLimit = 500

    public var limit: Int
    public var workspace: String?
    public var pane: String?
    /// Only leftover processes.
    public var leftover: Bool

    public init(limit: Int = ProcessListRequest.defaultLimit, workspace: String? = nil, pane: String? = nil,
                leftover: Bool = false) {
        self.limit = limit
        self.workspace = workspace
        self.pane = pane
        self.leftover = leftover
    }

    public init(params: JSONValue?) throws {
        self.init()
        switch params {
        case nil, .null?, .object?: break
        default: throw RPCError.invalidParams("params must be an object")
        }
        switch params?["limit"] {
        case nil, .null?: break
        case .number(let value)? where value >= 1 && value <= Double(Self.maxLimit) && value.rounded() == value:
            limit = Int(value)
        default: throw RPCError.invalidParams("limit must be a whole number from 1 to \(Self.maxLimit)")
        }
        func string(_ key: String) throws -> String? {
            switch params?[key] {
            case nil, .null?: return nil
            case .string(let value)? where !value.isEmpty: return value
            default: throw RPCError.invalidParams("\(key) must be a non-empty string")
            }
        }
        workspace = try string("workspace")
        pane = try string("pane")
        switch params?["leftover"] {
        case nil, .null?: break
        case .bool(let flag)?: leftover = flag
        default: throw RPCError.invalidParams("leftover must be a boolean")
        }
    }

    public var params: [String: JSONValue?] {
        [
            "limit": limit == Self.defaultLimit ? nil : .number(Double(limit)),
            "workspace": workspace.map { .string($0) },
            "pane": pane.map { .string($0) },
            "leftover": leftover ? .bool(true) : nil,
        ]
    }
}

/// Params of `system.kill_process`: `{pid, force?, started?}`. SIGTERM, or SIGKILL with `force`.
public struct ProcessKillRequest: Equatable, Sendable {
    public var pid: Int32
    public var force: Bool
    /// `ProcessEntry.started` as listed: refused when the pid now belongs to a process started at another time.
    public var started: Double?

    public init(pid: Int32, force: Bool = false, started: Double? = nil) {
        self.pid = pid
        self.force = force
        self.started = started
    }

    public init(params: JSONValue?) throws {
        guard case .number(let raw)? = params?["pid"], raw.rounded() == raw, raw >= 1, raw <= Double(Int32.max) else {
            throw RPCError.invalidParams("pid must be a positive whole number")
        }
        self.init(pid: Int32(raw))
        switch params?["force"] {
        case nil, .null?: break
        case .bool(let flag)?: force = flag
        default: throw RPCError.invalidParams("force must be a boolean")
        }
        switch params?["started"] {
        case nil, .null?: break
        case .number(let value)? where value.isFinite && value > 0: started = value
        default: throw RPCError.invalidParams("started must be seconds since 1970")
        }
    }

    public var params: [String: JSONValue?] {
        ["pid": .number(Double(pid)), "force": force ? .bool(true) : nil, "started": started.map { .number($0) }]
    }

    /// Checks the request against the latest scan. Only a process the scan attributed to a cmds terminal, still the
    /// same process (same start time), never pid 1 or the app itself.
    /// - Parameters:
    ///   - scanned: the latest scan's processes.
    ///   - currentStart: the pid's start time now (µs since 1970), nil when no such process exists.
    ///   - ownPID: the app's pid.
    /// - Returns: the process to signal.
    public func authorize(scanned: [ScannedProcess], currentStart: UInt64?, ownPID: Int32) throws -> ScannedProcess {
        guard pid > 1, pid != ownPID else {
            throw RPCError(code: 403, message: "pid \(pid) is not a process started from a cmds terminal")
        }
        guard let currentStart else { throw RPCError.notFound("no process \(pid)") }
        guard let process = scanned.first(where: { $0.pid == pid }), process.startMicroseconds == currentStart else {
            throw RPCError(code: 403, message: """
                pid \(pid) is not a process started from a cmds terminal; cmds stops only those (see cmds top). \
                Use kill or Activity Monitor for others.
                """)
        }
        if let started, abs(started - Double(currentStart) / 1_000_000) > 0.001 {
            throw RPCError(code: 409, message: "pid \(pid) is now another process (started at another time); list again")
        }
        return process
    }
}

/// Result of `system.kill_process`.
public struct ProcessKillResult: Codable, Equatable, Sendable {
    public var pid: Int32
    /// `TERM` or `KILL`.
    public var signal: String
    public var name: String

    public init(pid: Int32, signal: String, name: String) {
        self.pid = pid
        self.signal = signal
        self.name = name
    }
}

/// Where a process was first seen running (workspace, pane), kept for its lifetime: once its pane closes, a
/// detached process (nohup, `&`, a daemon) has lost its terminal and its parent, and only its environment
/// still names the pane, which macOS hides for Apple platform binaries (`sleep`, `make`, …).
public struct ProcessOrigins: Sendable {
    public struct Key: Hashable, Sendable {
        public var pid: Int32
        public var start: UInt64

        public init(pid: Int32, start: UInt64) {
            self.pid = pid
            self.start = start
        }
    }

    public struct Origin: Equatable, Sendable {
        public var workspace: String
        public var pane: String?

        public init(workspace: String, pane: String? = nil) {
            self.workspace = workspace
            self.pane = pane
        }
    }

    private var origins: [Key: Origin] = [:]

    public init() {}

    /// The process's origin: the first one seen for it, else this scan's. A pane learnt later fills in a missing one.
    public mutating func resolve(_ key: Key, workspace: String?, pane: String?) -> Origin? {
        if var known = origins[key] {
            if known.pane == nil, let pane, workspace == nil || workspace == known.workspace {
                known.pane = pane
                origins[key] = known
            }
            return known
        }
        guard let workspace else { return nil }
        let origin = Origin(workspace: workspace, pane: pane)
        origins[key] = origin
        return origin
    }

    /// Forgets processes that no longer exist.
    public mutating func keep(only alive: Set<Key>) {
        origins = origins.filter { alive.contains($0.key) }
    }

    public var count: Int { origins.count }
}

/// When to warn that memory is short (#193): pressure at warning or worse for `delay` seconds without a break, at
/// most once per `interval`.
public struct MemoryPressureAlarm: Sendable {
    public var delay: TimeInterval
    public var interval: TimeInterval
    private var since: Date?
    private var lastAlert: Date?

    public init(delay: TimeInterval = 60, interval: TimeInterval = 30 * 60) {
        self.delay = delay
        self.interval = interval
    }

    /// Feeds one reading; true when the warning should be shown now.
    public mutating func update(pressure: MemoryPressure, now: Date) -> Bool {
        guard pressure == .warning || pressure == .critical else {
            since = nil
            return false
        }
        let start = since ?? now
        since = start
        guard now.timeIntervalSince(start) >= delay else { return false }
        if let lastAlert, now.timeIntervalSince(lastAlert) < interval { return false }
        lastAlert = now
        return true
    }
}

/// `system_stats` advice for agents (`cmds mcp`): start a heavy job (build, test run) or wait.
public enum HeavyJobAdvice: String, Codable, Sendable {
    case ok
    case wait

    /// `wait` at pressure warning or critical (`kern.memorystatus_vm_pressure_level` ≥ 2).
    public init(_ stats: SystemStats?) {
        guard let level = stats?.memoryPressure else {
            self = .ok
            return
        }
        self = level >= 2 ? .wait : .ok
    }
}
