import Foundation

// MARK: - Files

/// `schedules.json`: `{"version": N, "schedules": [...]}`. Decoding is lenient: a schedule that cannot be decoded or
/// is invalid is dropped (and counted), not the whole file; unknown keys are ignored.
///
/// `version` is the lowest version whose builds run every schedule in the file as meant (`Schedule.requiredVersion`):
/// 1 while it holds only phase-1 schedules, 2 once one uses a phase-2 action or trigger. A build opens a file of a
/// higher version than `currentVersion` read only (shown, never run or saved over), so a phase-1 build never runs a
/// repeating trigger as a one-shot or drops a `sendText` schedule.
public struct ScheduleFile: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    public var schedules: [Schedule]
    /// Schedules dropped while decoding (not encoded).
    public var dropped = 0

    /// Written by a newer cmds: read only (never saved over).
    public var isFromNewerVersion: Bool { version > Self.currentVersion }

    public init(schedules: [Schedule] = [], version: Int? = nil) {
        self.version = version ?? Self.version(for: schedules)
        self.schedules = schedules
    }

    /// The version to write for `schedules`.
    public static func version(for schedules: [Schedule]) -> Int {
        schedules.map(\.requiredVersion).max() ?? 1
    }

    private enum CodingKeys: String, CodingKey { case version, schedules }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.lenientInt(.version) ?? 1
        let raw = try c.decodeIfPresent([LossyElement<Schedule>].self, forKey: .schedules) ?? []
        var seen = Set<String>()
        schedules = raw.compactMap(\.value).filter {
            ScheduleValidation.problems($0.draft).isEmpty && seen.insert($0.id).inserted
        }
        dropped = raw.count - schedules.count
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(schedules, forKey: .schedules)
    }

    public static func == (lhs: ScheduleFile, rhs: ScheduleFile) -> Bool {
        lhs.version == rhs.version && lhs.schedules == rhs.schedules
    }
}

/// `schedule-runs.json`: `{"version": 1, "runs": [...]}`, newest first. Stays at version 1: older builds read reason
/// codes they do not know as `other`.
public struct ScheduleRunsFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var runs: [ScheduleRun]

    public var isFromNewerVersion: Bool { version > Self.currentVersion }

    public init(runs: [ScheduleRun] = [], version: Int = ScheduleRunsFile.currentVersion) {
        self.version = version
        self.runs = runs
    }

    private enum CodingKeys: String, CodingKey { case version, runs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.lenientInt(.version) ?? 1
        runs = (try c.decodeIfPresent([LossyElement<ScheduleRun>].self, forKey: .runs) ?? []).compactMap(\.value)
    }
}

private struct LossyElement<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// The schedule files in the support directory (`CMDS_SUPPORT_DIR` for an isolated instance). Loaded through
/// `StoredFile` (a damaged file is moved aside, never overwritten); written atomically, readable by the user only
/// (prompts are stored in plain text).
public enum ScheduleStore {
    public static let fileName = "schedules.json"
    public static let runsFileName = "schedule-runs.json"

    public static func url(supportDirectory: URL = CmdsEnv.supportDirectoryURL()) -> URL {
        supportDirectory.appendingPathComponent(fileName)
    }

    public static func runsURL(supportDirectory: URL = CmdsEnv.supportDirectoryURL()) -> URL {
        supportDirectory.appendingPathComponent(runsFileName)
    }

    public static func save<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - History

public enum ScheduleHistory {
    /// Newest first, at most `maxRunsPerSchedule` per schedule and `maxRuns` in all, none older than `runRetention`.
    public static func trimmed(_ runs: [ScheduleRun], now: Date = Date()) -> [ScheduleRun] {
        let sorted = runs.sorted { $0.lastActivityAt > $1.lastActivityAt }
        var perSchedule: [String: Int] = [:]
        var kept: [ScheduleRun] = []
        for run in sorted {
            guard kept.count < ScheduleLimits.maxRuns else { break }
            guard now.timeIntervalSince(run.lastActivityAt) <= ScheduleLimits.runRetention else { continue }
            let count = perSchedule[run.scheduleID, default: 0]
            guard count < ScheduleLimits.maxRunsPerSchedule else { continue }
            perSchedule[run.scheduleID] = count + 1
            kept.append(run)
        }
        return kept
    }
}

// MARK: - API results

/// One schedule in `schedule.list` (`cmds schedule`).
public struct ScheduleListEntry: Codable, Equatable, Sendable {
    public var schedule: Schedule
    public var nextFireAt: Date?
    public var activeRun: ScheduleRun?
    public var lastRun: ScheduleRun?
    /// Why it cannot run as it is (e.g. its account was removed); nil when fine.
    public var problem: String?
    /// `sendText`: the pane its target is now (`p3`), if it resolves to one.
    public var targetPane: String?

    public init(schedule: Schedule, nextFireAt: Date? = nil, activeRun: ScheduleRun? = nil, lastRun: ScheduleRun? = nil,
                problem: String? = nil, targetPane: String? = nil) {
        self.schedule = schedule
        self.nextFireAt = nextFireAt
        self.activeRun = activeRun
        self.lastRun = lastRun
        self.problem = problem
        self.targetPane = targetPane
    }

    private enum CodingKeys: String, CodingKey { case schedule, nextFireAt, activeRun, lastRun, problem, targetPane }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schedule = try c.decode(Schedule.self, forKey: .schedule)
        nextFireAt = c.lenientDate(.nextFireAt)
        activeRun = try? c.decodeIfPresent(ScheduleRun.self, forKey: .activeRun)
        lastRun = try? c.decodeIfPresent(ScheduleRun.self, forKey: .lastRun)
        problem = c.lenientString(.problem)
        targetPane = c.lenientString(.targetPane)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schedule, forKey: .schedule)
        try c.encodeIfPresent(nextFireAt?.timeIntervalSince1970, forKey: .nextFireAt)
        try c.encodeIfPresent(activeRun, forKey: .activeRun)
        try c.encodeIfPresent(lastRun, forKey: .lastRun)
        try c.encodeIfPresent(problem, forKey: .problem)
        try c.encodeIfPresent(targetPane, forKey: .targetPane)
    }
}

/// Result of `schedule.list`.
public struct ScheduleList: Codable, Equatable, Sendable {
    public var schedules: [ScheduleListEntry]
    /// The files were written by a newer cmds (or could not be read): nothing is saved.
    public var readOnly: Bool

    public init(schedules: [ScheduleListEntry], readOnly: Bool = false) {
        self.schedules = schedules
        self.readOnly = readOnly
    }
}

/// Result of `schedule.history`.
public struct ScheduleHistoryList: Codable, Equatable, Sendable {
    public var runs: [ScheduleRun]

    public init(runs: [ScheduleRun]) { self.runs = runs }
}
