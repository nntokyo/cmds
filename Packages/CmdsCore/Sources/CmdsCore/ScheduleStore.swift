import Foundation

// MARK: - Validation

/// Something wrong with a schedule. `english` for the API and CLI; the app localizes its own text.
public enum ScheduleProblem: Equatable, Sendable {
    case nameInvalid
    case tooManySchedules
    case onceInPast
    case noWeekdays
    case timesCount
    case timesTooClose
    case unknownTimeZone(String)
    case delayOutOfRange
    case lateOutOfRange
    case accountInvalid(String)
    case accountUnknown(String)
    case accountNotLimited(String)
    case noAccounts
    case folderInvalid
    case titleInvalid
    case commandInvalid
    case promptWithoutCommand
    case promptInvalid
    case promptTooLong
    case agentUnsupported
    case sessionIDInvalid

    public var english: String {
        switch self {
        case .nameInvalid: return "the name must be 1 to \(ScheduleLimits.maxNameLength) characters without control characters"
        case .tooManySchedules: return "at most \(ScheduleLimits.maxSchedules) schedules"
        case .onceInPast: return "the time has already passed"
        case .noWeekdays: return "choose at least one weekday"
        case .timesCount: return "give 1 to \(ScheduleLimits.maxTimesPerDay) times of day"
        case .timesTooClose: return "times of day must be at least 5 minutes apart"
        case .unknownTimeZone(let zone): return "unknown time zone \(zone)"
        case .delayOutOfRange: return "the delay must be 0 to 60 minutes"
        case .lateOutOfRange: return "a late run must be allowed for 1 minute to 7 days"
        case .accountInvalid(let name): return "\(name) is not a valid account name"
        case .accountUnknown(let name): return "no account named \(name)"
        case .accountNotLimited(let name): return "account \(name) has no limit now"
        case .noAccounts: return "no accounts (cmds accounts add NAME DIR)"
        case .folderInvalid: return "the folder must be an absolute path or start with ~/"
        case .titleInvalid: return "the title must be at most \(ScheduleLimits.maxTitleLength) characters without control characters"
        case .commandInvalid: return "the command must be one line of at most 1 KB without control characters"
        case .promptWithoutCommand: return "a prompt needs a command that starts Claude Code"
        case .promptInvalid: return "the prompt must not be empty or contain control characters other than line breaks and tabs"
        case .promptTooLong: return "the prompt must be at most 8 KB"
        case .agentUnsupported: return "only Claude Code sessions can be continued"
        case .sessionIDInvalid: return "the session id is not valid"
        }
    }
}

public enum ScheduleValidation {
    /// Problems of the schedule itself, independent of accounts and time. A stored schedule with any is dropped.
    public static func problems(_ draft: ScheduleDraft) -> [ScheduleProblem] {
        var problems: [ScheduleProblem] = []
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || draft.name.count > ScheduleLimits.maxNameLength || hasControlCharacters(draft.name) {
            problems.append(.nameInvalid)
        }
        switch draft.trigger {
        case .once:
            break
        case .weekly(let rule):
            if rule.weekdays.isEmpty { problems.append(.noWeekdays) }
            if !(1...ScheduleLimits.maxTimesPerDay).contains(rule.times.count) { problems.append(.timesCount) }
            if !timesApart(rule.times) { problems.append(.timesTooClose) }
            if let zone = rule.timeZone, TimeZone(identifier: zone) == nil { problems.append(.unknownTimeZone(zone)) }
        case .limitReset(let account, let delay):
            if ClaudeAccounts.nameProblem(account) != nil { problems.append(.accountInvalid(account)) }
            if !(0...ScheduleLimits.maxDelay).contains(delay) { problems.append(.delayOutOfRange) }
        }
        if case .runIfWithin(let seconds) = draft.late, !(60...ScheduleLimits.maxLateWindow).contains(seconds) {
            problems.append(.lateOutOfRange)
        }
        switch draft.action {
        case .startWorkspace(let action):
            if !isFolder(action.cwd) { problems.append(.folderInvalid) }
            if let title = action.title, title.count > ScheduleLimits.maxTitleLength || hasControlCharacters(title) {
                problems.append(.titleInvalid)
            }
            if let account = action.account, account.lowercased() != ClaudeAccounts.automatic,
               ClaudeAccounts.nameProblem(account) != nil {
                problems.append(.accountInvalid(account))
            }
            if let command = action.command, !isCommand(command) { problems.append(.commandInvalid) }
            if let prompt = action.prompt {
                if action.command == nil { problems.append(.promptWithoutCommand) }
                problems += promptProblems(prompt)
            }
        case .continueSession(let action):
            if action.agent != .claude { problems.append(.agentUnsupported) }
            if !AgentResume.isValidSessionID(action.sessionID) { problems.append(.sessionIDInvalid) }
            if let cwd = action.cwd, !isFolder(cwd) { problems.append(.folderInvalid) }
            if let account = action.account, ClaudeAccounts.nameProblem(account) != nil {
                problems.append(.accountInvalid(account))
            }
            problems += promptProblems(action.prompt)
        }
        return problems
    }

    /// Everything checked when a schedule is created or changed: `problems(_:)` plus the accounts it names, a time
    /// that is still ahead, an account limit for `limitReset`, and the number of schedules (`existing`, without this
    /// one).
    public static func problems(_ draft: ScheduleDraft, accounts: [ClaudeAccount], existing: Int,
                                now: Date = Date()) -> [ScheduleProblem] {
        var problems = problems(draft)
        if existing >= ScheduleLimits.maxSchedules { problems.append(.tooManySchedules) }
        func checkAccount(_ name: String?) {
            guard let name else { return }
            if name.lowercased() == ClaudeAccounts.automatic {
                if accounts.isEmpty { problems.append(.noAccounts) }
                return
            }
            // An invalid name is already reported.
            if ClaudeAccounts.nameProblem(name) == nil, !accounts.contains(where: { $0.hasName(name) }) {
                problems.append(.accountUnknown(name))
            }
        }
        switch draft.trigger {
        case .once(let at):
            if at <= now { problems.append(.onceInPast) }
        case .weekly:
            break
        case .limitReset(let account, _):
            if ClaudeAccounts.nameProblem(account) == nil {
                if let found = accounts.first(where: { $0.hasName(account) }) {
                    if !found.isLimited(at: now) { problems.append(.accountNotLimited(found.name)) }
                } else {
                    problems.append(.accountUnknown(account))
                }
            }
        }
        switch draft.action {
        case .startWorkspace(let action): checkAccount(action.account)
        case .continueSession(let action):
            // `auto` is not an account for a session (already reported as invalid).
            if action.account?.lowercased() != ClaudeAccounts.automatic { checkAccount(action.account) }
        }
        return problems
    }

    /// Any control character (names, titles, commands, folders).
    static func hasControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) || $0 == "\u{2028}" || $0 == "\u{2029}" }
    }

    /// Absolute or `~/…`, without control characters.
    static func isFolder(_ path: String) -> Bool {
        (path.hasPrefix("/") || path == "~" || path.hasPrefix("~/")) && path.count <= 1024 && !hasControlCharacters(path)
    }

    /// One line, at most 1 KB, no control characters, not blank.
    static func isCommand(_ command: String) -> Bool {
        !command.trimmingCharacters(in: .whitespaces).isEmpty && command.utf8.count <= ScheduleLimits.maxCommandBytes
            && !hasControlCharacters(command)
    }

    /// A prompt is pasted (bracketed paste): line breaks and tabs are fine; any other control character (ESC could end
    /// the paste early and type the rest as keys) is refused.
    static func promptProblems(_ prompt: String) -> [ScheduleProblem] {
        var problems: [ScheduleProblem] = []
        let invalid = prompt.unicodeScalars.contains {
            ($0.value < 0x20 && $0 != "\n" && $0 != "\t") || (0x7F...0x9F).contains($0.value)
        }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || invalid { problems.append(.promptInvalid) }
        if prompt.utf8.count > ScheduleLimits.maxPromptBytes { problems.append(.promptTooLong) }
        return problems
    }

    /// Sorted times at least `minTimeGap` apart, also from the last one of a day to the first of the next.
    static func timesApart(_ times: [TimeOfDay]) -> Bool {
        let minutes = times.map(\.minutes).sorted()
        let gap = Int(ScheduleLimits.minTimeGap / 60)
        for (a, b) in zip(minutes, minutes.dropFirst()) where b - a < gap { return false }
        if minutes.count > 1, let first = minutes.first, let last = minutes.last, first + 24 * 60 - last < gap { return false }
        return true
    }
}

// MARK: - Files

/// `schedules.json`: `{"version": 1, "schedules": [...]}`. Decoding is lenient: a schedule that cannot be decoded or
/// is invalid is dropped (and counted), not the whole file; unknown keys are ignored.
public struct ScheduleFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var schedules: [Schedule]
    /// Schedules dropped while decoding (not encoded).
    public var dropped = 0

    /// Written by a newer cmds: read only (never saved over).
    public var isFromNewerVersion: Bool { version > Self.currentVersion }

    public init(schedules: [Schedule] = [], version: Int = ScheduleFile.currentVersion) {
        self.version = version
        self.schedules = schedules
    }

    private enum CodingKeys: String, CodingKey { case version, schedules }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.lenientInt(.version) ?? 1
        let raw = try c.decodeIfPresent([LossySchedule<Schedule>].self, forKey: .schedules) ?? []
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

/// `schedule-runs.json`: `{"version": 1, "runs": [...]}`, newest first.
public struct ScheduleRunsFile: Codable, Equatable, Sendable {
    public var version: Int
    public var runs: [ScheduleRun]

    public var isFromNewerVersion: Bool { version > ScheduleFile.currentVersion }

    public init(runs: [ScheduleRun] = [], version: Int = ScheduleFile.currentVersion) {
        self.version = version
        self.runs = runs
    }

    private enum CodingKeys: String, CodingKey { case version, runs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.lenientInt(.version) ?? 1
        runs = (try c.decodeIfPresent([LossySchedule<ScheduleRun>].self, forKey: .runs) ?? []).compactMap(\.value)
    }
}

private struct LossySchedule<Value: Decodable>: Decodable {
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
        let sorted = runs.sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
        var perSchedule: [String: Int] = [:]
        var kept: [ScheduleRun] = []
        for run in sorted {
            guard kept.count < ScheduleLimits.maxRuns else { break }
            guard now.timeIntervalSince(run.endedAt ?? run.startedAt) <= ScheduleLimits.runRetention else { continue }
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

    public init(schedule: Schedule, nextFireAt: Date? = nil, activeRun: ScheduleRun? = nil, lastRun: ScheduleRun? = nil,
                problem: String? = nil) {
        self.schedule = schedule
        self.nextFireAt = nextFireAt
        self.activeRun = activeRun
        self.lastRun = lastRun
        self.problem = problem
    }

    private enum CodingKeys: String, CodingKey { case schedule, nextFireAt, activeRun, lastRun, problem }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schedule = try c.decode(Schedule.self, forKey: .schedule)
        nextFireAt = c.lenientDate(.nextFireAt)
        activeRun = try? c.decodeIfPresent(ScheduleRun.self, forKey: .activeRun)
        lastRun = try? c.decodeIfPresent(ScheduleRun.self, forKey: .lastRun)
        problem = c.lenientString(.problem)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schedule, forKey: .schedule)
        try c.encodeIfPresent(nextFireAt?.timeIntervalSince1970, forKey: .nextFireAt)
        try c.encodeIfPresent(activeRun, forKey: .activeRun)
        try c.encodeIfPresent(lastRun, forKey: .lastRun)
        try c.encodeIfPresent(problem, forKey: .problem)
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
