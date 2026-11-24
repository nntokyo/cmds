import Foundation

/// `cmds doctor` (#454): what is degraded in a running cmds, for agents and scripts on a Mac nobody watches. The app
/// fills a `DoctorSnapshot`; the checks here turn it into findings (English), so they are tested without an app.
public struct DoctorFinding: Codable, Equatable, Sendable {
    public enum Level: String, Codable, Sendable, Comparable {
        case ok, note, warn

        private var rank: Int { [.ok: 0, .note: 1, .warn: 2][self] ?? 0 }
        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rank < rhs.rank }
    }

    /// Stable: `version`, `update`, `resume`, `login`, `schedules`, `hangs`, `memory`, `bluetooth`.
    public var id: String
    public var level: Level
    public var text: String
    /// What to do (nil when nothing).
    public var fix: String?

    public init(id: String, level: Level, text: String, fix: String? = nil) {
        self.id = id
        self.level = level
        self.text = text
        self.fix = fix
    }

    private enum CodingKeys: String, CodingKey { case id, level, text, fix }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientString(.id) ?? ""
        level = (try? c.decode(Level.self, forKey: .level)) ?? .note
        text = c.lenientString(.text) ?? ""
        fix = c.lenientString(.fix)
    }
}

/// Result of `app.doctor`.
public struct DoctorReport: Codable, Equatable, Sendable {
    public var findings: [DoctorFinding]

    public init(findings: [DoctorFinding]) { self.findings = findings }

    /// The worst level found.
    public var level: DoctorFinding.Level { findings.map(\.level).max() ?? .ok }
}

/// What the app knows, gathered on the main thread.
public struct DoctorSnapshot: Equatable, Sendable {
    public var runningVersion: String
    public var runningBuild: String
    /// The version and build of the app bundle on disk now (nil when unreadable).
    public var diskVersion: String?
    public var diskBuild: String?
    /// An update Sparkle has downloaded and installs when cmds quits.
    public var updateOnQuit: String?
    /// `ask`, `always`, `never`.
    public var resumeMode: String
    public var loginItem: LoginItemState
    public var schedulesReadOnly: String?
    public var schedulesMovedAside: [String]
    /// `name: problem` per schedule that cannot run as it is.
    public var scheduleProblems: [String]
    /// Dropped from `schedules.json` in the last 7 days (Recently Deleted).
    public var schedulesDropped: Int
    /// Hang samples in the last 24 h, newest first (file names).
    public var recentHangs: [String]
    public var memoryPressure: MemoryPressure
    /// Bluetooth sync allowed and running; nil when off or not wanted.
    public var bluetoothStatus: String?
    public var bluetoothFailures: Int

    public init(runningVersion: String, runningBuild: String, diskVersion: String? = nil, diskBuild: String? = nil,
                updateOnQuit: String? = nil, resumeMode: String = "ask", loginItem: LoginItemState = LoginItemState(status: .off),
                schedulesReadOnly: String? = nil, schedulesMovedAside: [String] = [], scheduleProblems: [String] = [],
                schedulesDropped: Int = 0, recentHangs: [String] = [], memoryPressure: MemoryPressure = .normal,
                bluetoothStatus: String? = nil, bluetoothFailures: Int = 0) {
        self.runningVersion = runningVersion
        self.runningBuild = runningBuild
        self.diskVersion = diskVersion
        self.diskBuild = diskBuild
        self.updateOnQuit = updateOnQuit
        self.resumeMode = resumeMode
        self.loginItem = loginItem
        self.schedulesReadOnly = schedulesReadOnly
        self.schedulesMovedAside = schedulesMovedAside
        self.scheduleProblems = scheduleProblems
        self.schedulesDropped = schedulesDropped
        self.recentHangs = recentHangs
        self.memoryPressure = memoryPressure
        self.bluetoothStatus = bluetoothStatus
        self.bluetoothFailures = bluetoothFailures
    }
}

public enum Doctor {
    /// Bluetooth failures in a row before it is a warning (the first retries are seconds apart).
    public static let bluetoothWarnAfter = 3

    public static func report(_ s: DoctorSnapshot) -> DoctorReport {
        DoctorReport(findings: [version(s), resume(s), login(s), schedules(s), hangs(s), memory(s), bluetooth(s)].compactMap { $0 })
    }

    static func version(_ s: DoctorSnapshot) -> DoctorFinding {
        let running = "cmds \(s.runningVersion) (\(s.runningBuild))"
        if let update = s.updateOnQuit {
            return DoctorFinding(id: "update", level: .note, text: "\(running); \(update) is downloaded and installs when cmds quits",
                                 fix: "it starts the next time cmds is reopened")
        }
        if let disk = s.diskBuild, let diskBuild = Int(disk), let build = Int(s.runningBuild), diskBuild > build {
            return DoctorFinding(id: "update", level: .note,
                                 text: "\(running) runs; \(s.diskVersion ?? "a newer version") (\(disk)) is installed",
                                 fix: "it starts the next time cmds is reopened")
        }
        if s.diskBuild == nil {
            return DoctorFinding(id: "version", level: .warn, text: "\(running) runs, but its app is no longer where it started",
                                 fix: "reopen cmds from the Applications folder")
        }
        return DoctorFinding(id: "version", level: .ok, text: running)
    }

    static func resume(_ s: DoctorSnapshot) -> DoctorFinding {
        switch s.resumeMode {
        case "always":
            return DoctorFinding(id: "resume", level: .ok, text: "agent sessions resume by themselves after a restart")
        case "never":
            return DoctorFinding(id: "resume", level: .note, text: "agent sessions are forgotten after a restart",
                                 fix: "View › Resume Agent Sessions on Launch › Always")
        default:
            return DoctorFinding(id: "resume", level: .note, text: "after a restart, agent sessions wait for someone to click Resume",
                                 fix: "View › Resume Agent Sessions on Launch › Always")
        }
    }

    static func login(_ s: DoctorSnapshot) -> DoctorFinding {
        switch s.loginItem.status {
        case .on: return DoctorFinding(id: "login", level: .ok, text: "cmds opens at login")
        case .off: return DoctorFinding(id: "login", level: .note, text: "cmds does not open at login: after a restart nothing runs until it is opened",
                                        fix: "cmds launch-at-login on")
        case .needsApproval: return DoctorFinding(id: "login", level: .warn, text: "cmds is a login item, but macOS has it switched off",
                                                  fix: LoginItemPolicy.approvalHint)
        case .unavailable: return DoctorFinding(id: "login", level: .note, text: "cmds cannot open at login: " + (s.loginItem.problem ?? "unavailable"))
        }
    }

    static func schedules(_ s: DoctorSnapshot) -> DoctorFinding {
        var problems: [String] = []
        var fixes: [String] = []
        if let reason = s.schedulesReadOnly {
            problems.append("schedules are read only (\(reason)): none run")
        }
        if !s.schedulesMovedAside.isEmpty {
            problems.append("damaged schedule files were set aside: " + s.schedulesMovedAside.joined(separator: ", "))
        }
        if !s.scheduleProblems.isEmpty {
            problems.append("cannot run as they are: " + s.scheduleProblems.joined(separator: "; "))
            fixes.append("cmds schedule")
        }
        if s.schedulesDropped > 0 {
            problems.append("\(s.schedulesDropped) dropped from schedules.json in the last 7 days")
            fixes.append("cmds schedule deleted")
        }
        guard !problems.isEmpty else { return DoctorFinding(id: "schedules", level: .ok, text: "schedules are fine") }
        return DoctorFinding(id: "schedules", level: .warn, text: problems.joined(separator: "; "),
                             fix: fixes.isEmpty ? nil : fixes.joined(separator: ", "))
    }

    static func hangs(_ s: DoctorSnapshot) -> DoctorFinding {
        guard let newest = s.recentHangs.first else { return DoctorFinding(id: "hangs", level: .ok, text: "no hangs in the last 24 h") }
        return DoctorFinding(id: "hangs", level: .warn,
                             text: "\(s.recentHangs.count) hang\(s.recentHangs.count == 1 ? "" : "s") in the last 24 h (newest: hangs/\(newest))",
                             fix: "attach the sample to an issue")
    }

    static func memory(_ s: DoctorSnapshot) -> DoctorFinding {
        switch s.memoryPressure {
        case .normal: return DoctorFinding(id: "memory", level: .ok, text: "memory pressure normal")
        case .warning: return DoctorFinding(id: "memory", level: .warn, text: "memory pressure warning", fix: "cmds stats; close what is not needed before heavy jobs")
        case .critical: return DoctorFinding(id: "memory", level: .warn, text: "memory pressure critical", fix: "cmds stats; close what is not needed")
        case .unknown: return DoctorFinding(id: "memory", level: .note, text: "memory pressure not measured yet")
        }
    }

    static func bluetooth(_ s: DoctorSnapshot) -> DoctorFinding? {
        guard let status = s.bluetoothStatus else { return nil }
        guard s.bluetoothFailures >= bluetoothWarnAfter else {
            return DoctorFinding(id: "bluetooth", level: .ok, text: "Bluetooth sync: " + status)
        }
        return DoctorFinding(id: "bluetooth", level: .warn,
                             text: "Bluetooth sync failed \(s.bluetoothFailures) times in a row: " + status,
                             fix: "the iPhone still syncs over the network; turning Bluetooth off and on starts it over")
    }
}
