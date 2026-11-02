import Foundation

// Schedules (docs/guide/schedules.md, design: GitHub issue #45): start a workspace or continue a Claude Code session
// at a set time, on a weekly repeat, or when an account's limit resets. CmdsCore has the model, its file format,
// validation and the pure rules (ScheduleCalendar, ScheduleRunTiming); the app's ScheduleRunner runs them.

/// A day of the week as stored (`"mon"`…`"sun"`).
public enum Weekday: String, Codable, CaseIterable, Comparable, Sendable {
    case mon, tue, wed, thu, fri, sat, sun

    /// `Calendar`'s weekday number (1 = Sunday).
    public var calendarWeekday: Int {
        switch self {
        case .sun: return 1
        case .mon: return 2
        case .tue: return 3
        case .wed: return 4
        case .thu: return 5
        case .fri: return 6
        case .sat: return 7
        }
    }

    public init?(calendarWeekday: Int) {
        guard let day = Weekday.allCases.first(where: { $0.calendarWeekday == calendarWeekday }) else { return nil }
        self = day
    }

    /// Monday to Friday.
    public static let workdays: Set<Weekday> = [.mon, .tue, .wed, .thu, .fri]

    private var order: Int { Weekday.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: Weekday, rhs: Weekday) -> Bool { lhs.order < rhs.order }
}

/// A wall-clock time, stored as `"HH:mm"`.
public struct TimeOfDay: Codable, Hashable, Comparable, Sendable {
    public var hour: Int
    public var minute: Int

    public init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    /// `"9:00"`, `"09:00"`; nil for anything else.
    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        self.init(hour: hour, minute: minute)
    }

    /// Minutes after midnight.
    public var minutes: Int { hour * 60 + minute }
    /// `"09:00"`.
    public var text: String { String(format: "%02d:%02d", hour, minute) }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool { lhs.minutes < rhs.minutes }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = TimeOfDay(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not HH:mm: \(raw)"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
    }
}

/// `weekly`: some weekdays at some times of day.
public struct WeeklyRule: Codable, Equatable, Sendable {
    /// Not empty.
    public var weekdays: Set<Weekday>
    /// Sorted, 1…24, at least 5 minutes apart.
    public var times: [TimeOfDay]
    /// IANA id; nil follows the Mac's current zone.
    public var timeZone: String?

    public init(weekdays: Set<Weekday>, times: [TimeOfDay], timeZone: String? = nil) {
        self.weekdays = weekdays
        self.times = times.sorted()
        self.timeZone = timeZone
    }

    private enum CodingKeys: String, CodingKey { case weekdays, times, timeZone }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weekdays = Set(try c.decode([Weekday].self, forKey: .weekdays))
        times = try c.decode([TimeOfDay].self, forKey: .times).sorted()
        timeZone = c.lenientString(.timeZone)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(weekdays.sorted(), forKey: .weekdays)
        try c.encode(times, forKey: .times)
        try c.encodeIfPresent(timeZone, forKey: .timeZone)
    }
}

/// When a schedule fires.
public enum ScheduleTrigger: Equatable, Sendable {
    case once(at: Date)
    case weekly(WeeklyRule)
    /// When the account's current limit resets, plus `delay` (0…3600 s). Fires once.
    case limitReset(account: String, delay: TimeInterval)

    public var type: String {
        switch self {
        case .once: return "once"
        case .weekly: return "weekly"
        case .limitReset: return "limitReset"
        }
    }

    /// `once` and `limitReset` fire one time; the schedule is then disabled (and kept).
    public var isOneShot: Bool {
        if case .weekly = self { return false }
        return true
    }
}

extension ScheduleTrigger: Codable {
    private enum CodingKeys: String, CodingKey { case type, at, weekdays, times, timeZone, account, delay }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "once":
            guard let at = c.lenientDate(.at) else {
                throw DecodingError.dataCorruptedError(forKey: .at, in: c, debugDescription: "missing time")
            }
            self = .once(at: at)
        case "weekly":
            self = .weekly(try WeeklyRule(from: decoder))
        case "limitReset":
            guard let account = c.lenientString(.account) else {
                throw DecodingError.dataCorruptedError(forKey: .account, in: c, debugDescription: "missing account")
            }
            self = .limitReset(account: account, delay: c.lenientDouble(.delay) ?? ScheduleLimits.defaultDelay)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown trigger type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .once(let at):
            try c.encode(at.timeIntervalSince1970, forKey: .at)
        case .weekly(let rule):
            try rule.encode(to: encoder)
        case .limitReset(let account, let delay):
            try c.encode(account, forKey: .account)
            try c.encode(delay, forKey: .delay)
        }
    }
}

/// `startWorkspace`: a new background workspace; optionally a command typed at its shell prompt and a first prompt
/// pasted into the Claude Code it starts.
public struct StartWorkspace: Codable, Equatable, Sendable {
    /// Absolute or `~/…`.
    public var cwd: String
    public var title: String?
    /// An account name, `auto`, or nil (the shell's own environment).
    public var account: String?
    /// Typed at the new shell's prompt, then Return. One line.
    public var command: String?
    /// Requires `command`; pasted once Claude Code is idle.
    public var prompt: String?

    public init(cwd: String, title: String? = nil, account: String? = nil, command: String? = nil, prompt: String? = nil) {
        self.cwd = cwd
        self.title = title
        self.account = account
        self.command = command
        self.prompt = prompt
    }

    private enum CodingKeys: String, CodingKey { case cwd, title, account, command, prompt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let cwd = c.lenientString(.cwd) else {
            throw DecodingError.dataCorruptedError(forKey: .cwd, in: c, debugDescription: "missing cwd")
        }
        self.cwd = cwd
        title = c.lenientString(.title)
        account = c.lenientString(.account)
        command = c.lenientString(.command)
        prompt = c.lenientString(.prompt)
    }
}

/// `continueSession`: a remembered Claude Code session gets a prompt; resumed first when it is not running.
public struct ContinueSession: Codable, Equatable, Sendable {
    /// `.claude` only in phase 1.
    public var agent: AgentKind
    public var sessionID: String
    /// Where to resume it in a new workspace when no pane holds it.
    public var cwd: String?
    /// nil = the session's account.
    public var account: String?
    public var prompt: String

    public static let defaultPrompt = "continue"

    public init(agent: AgentKind = .claude, sessionID: String, cwd: String? = nil, account: String? = nil,
                prompt: String = ContinueSession.defaultPrompt) {
        self.agent = agent
        self.sessionID = sessionID
        self.cwd = cwd
        self.account = account
        self.prompt = prompt
    }

    private enum CodingKeys: String, CodingKey { case agent, sessionID, cwd, account, prompt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent = (try? c.decode(AgentKind.self, forKey: .agent)) ?? .claude
        guard let id = c.lenientString(.sessionID) else {
            throw DecodingError.dataCorruptedError(forKey: .sessionID, in: c, debugDescription: "missing session id")
        }
        sessionID = id
        cwd = c.lenientString(.cwd)
        account = c.lenientString(.account)
        prompt = c.lenientString(.prompt) ?? Self.defaultPrompt
    }
}

/// What a schedule does.
public enum ScheduleAction: Equatable, Sendable {
    case startWorkspace(StartWorkspace)
    case continueSession(ContinueSession)

    public var type: String {
        switch self {
        case .startWorkspace: return "startWorkspace"
        case .continueSession: return "continueSession"
        }
    }
}

extension ScheduleAction: Codable {
    private enum CodingKeys: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "startWorkspace": self = .startWorkspace(try StartWorkspace(from: decoder))
        case "continueSession": self = .continueSession(try ContinueSession(from: decoder))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown action type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .startWorkspace(let action): try action.encode(to: encoder)
        case .continueSession(let action): try action.encode(to: encoder)
        }
    }
}

/// What happens when a firing time passed while the Mac slept or cmds was not running.
public enum ScheduleLatePolicy: Equatable, Sendable {
    /// Missed: noted in the history, not run.
    case skip
    /// One catch-up run when late by at most this long.
    case runIfWithin(TimeInterval)

    /// `once` and `limitReset`: up to 6 h late; `weekly`: up to 15 min.
    public static func defaultPolicy(for trigger: ScheduleTrigger) -> ScheduleLatePolicy {
        trigger.isOneShot ? .runIfWithin(6 * 3600) : .runIfWithin(15 * 60)
    }
}

extension ScheduleLatePolicy: Codable {
    private enum CodingKeys: String, CodingKey { case type, seconds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "skip": self = .skip
        case "runIfWithin":
            guard let seconds = c.lenientDouble(.seconds) else {
                throw DecodingError.dataCorruptedError(forKey: .seconds, in: c, debugDescription: "missing seconds")
            }
            self = .runIfWithin(seconds)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown late policy \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .skip:
            try c.encode("skip", forKey: .type)
        case .runIfWithin(let seconds):
            try c.encode("runIfWithin", forKey: .type)
            try c.encode(seconds, forKey: .seconds)
        }
    }
}

/// Which runs tell the user.
public enum ScheduleNotify: String, Codable, CaseIterable, Sendable {
    /// Failed, skipped and missed runs (default).
    case failures
    case always
    case never
}

/// Who created a schedule (shown in the window, so schedules made by an agent are visible).
public enum ScheduleOrigin: Equatable, Sendable {
    case app
    /// The socket API; `pane` is the caller's `CMDS_PANE_ID` when it ran in a cmds terminal.
    case api(pane: String?)
}

extension ScheduleOrigin: Codable {
    private enum CodingKeys: String, CodingKey { case type, pane }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch c.lenientString(.type) {
        case "api": self = .api(pane: c.lenientString(.pane))
        default: self = .app
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .app:
            try c.encode("app", forKey: .type)
        case .api(let pane):
            try c.encode("api", forKey: .type)
            try c.encodeIfPresent(pane, forKey: .pane)
        }
    }
}

/// The parts of a schedule a user or script chooses (`schedule.add`, the editor sheet).
public struct ScheduleDraft: Codable, Equatable, Sendable {
    public var name: String
    public var enabled: Bool
    public var trigger: ScheduleTrigger
    public var action: ScheduleAction
    public var late: ScheduleLatePolicy
    public var notify: ScheduleNotify

    public init(name: String, enabled: Bool = true, trigger: ScheduleTrigger, action: ScheduleAction,
                late: ScheduleLatePolicy? = nil, notify: ScheduleNotify = .failures) {
        self.name = name
        self.enabled = enabled
        self.trigger = trigger
        self.action = action
        self.late = late ?? .defaultPolicy(for: trigger)
        self.notify = notify
    }

    private enum CodingKeys: String, CodingKey { case name, enabled, trigger, action, late, notify }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.lenientString(.name) ?? ""
        enabled = c.lenientBool(.enabled) ?? true
        trigger = try c.decode(ScheduleTrigger.self, forKey: .trigger)
        action = try c.decode(ScheduleAction.self, forKey: .action)
        late = (try? c.decodeIfPresent(ScheduleLatePolicy.self, forKey: .late)) ?? .defaultPolicy(for: trigger)
        notify = (try? c.decodeIfPresent(ScheduleNotify.self, forKey: .notify)) ?? .failures
    }
}

/// One schedule (`schedules.json`).
public struct Schedule: Codable, Equatable, Sendable {
    /// `"s"` + 8 lowercase hex digits.
    public var id: String
    public var name: String
    public var enabled: Bool
    public var trigger: ScheduleTrigger
    public var action: ScheduleAction
    public var late: ScheduleLatePolicy
    public var notify: ScheduleNotify
    public var origin: ScheduleOrigin
    public var createdAt: Date
    /// nil = no further firing (a one-shot that is done, or a disabled schedule).
    public var nextFireAt: Date?

    public init(id: String, draft: ScheduleDraft, origin: ScheduleOrigin, createdAt: Date, nextFireAt: Date? = nil) {
        self.id = id
        name = draft.name
        enabled = draft.enabled
        trigger = draft.trigger
        action = draft.action
        late = draft.late
        notify = draft.notify
        self.origin = origin
        self.createdAt = createdAt
        self.nextFireAt = nextFireAt
    }

    /// The parts the user chose.
    public var draft: ScheduleDraft {
        get { ScheduleDraft(name: name, enabled: enabled, trigger: trigger, action: action, late: late, notify: notify) }
        set {
            name = newValue.name
            enabled = newValue.enabled
            trigger = newValue.trigger
            action = newValue.action
            late = newValue.late
            notify = newValue.notify
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, trigger, action, late, notify, origin, createdAt, nextFireAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lenientString(.id), ScheduleIDs.isValid(id, prefix: ScheduleIDs.schedulePrefix) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "invalid schedule id")
        }
        self.id = id
        let draft = try ScheduleDraft(from: decoder)
        name = draft.name
        enabled = draft.enabled
        trigger = draft.trigger
        action = draft.action
        late = draft.late
        notify = draft.notify
        origin = (try? c.decodeIfPresent(ScheduleOrigin.self, forKey: .origin)) ?? .app
        createdAt = c.lenientDate(.createdAt) ?? Date(timeIntervalSince1970: 0)
        nextFireAt = c.lenientDate(.nextFireAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(trigger, forKey: .trigger)
        try c.encode(action, forKey: .action)
        try c.encode(late, forKey: .late)
        try c.encode(notify, forKey: .notify)
        try c.encode(origin, forKey: .origin)
        try c.encode(createdAt.timeIntervalSince1970, forKey: .createdAt)
        try c.encodeIfPresent(nextFireAt?.timeIntervalSince1970, forKey: .nextFireAt)
    }
}

// MARK: - Runs

/// Where a run is. Active states first, then the final ones.
public enum ScheduleRunState: String, Codable, CaseIterable, Sendable {
    /// The account is limited (or, with `auto`, every account is); waits for its reset within `accountWait`.
    case waitingForAccount
    /// Waits for the pane's shell to sit at an empty prompt.
    case waitingForPane
    /// The prompt was pasted into Claude Code; Return follows.
    case typing
    /// Waits for Claude Code to be idle (not busy, not asking, no subagent, screen settled).
    case waitingForAgent
    /// Return was sent; waits for Claude Code to start working.
    case confirming
    case succeeded
    case failed
    case skipped
    case missed
    case cancelled

    public var isActive: Bool {
        switch self {
        case .waitingForAccount, .waitingForPane, .typing, .waitingForAgent, .confirming: return true
        case .succeeded, .failed, .skipped, .missed, .cancelled: return false
        }
    }

    /// Failed, skipped and missed runs tell the user (unless the schedule says never).
    public var isProblem: Bool { self == .failed || self == .skipped || self == .missed }
}

/// One firing of a schedule (`schedule-runs.json`, newest first).
public struct ScheduleRun: Codable, Equatable, Sendable {
    public enum Cause: String, Codable, Sendable {
        case scheduled
        /// The firing time passed while the Mac slept or cmds was not running (within the late policy).
        case catchUp
        /// Run Now / `cmds schedule run`.
        case manual
    }

    /// `"r"` + 8 lowercase hex digits.
    public var id: String
    public var scheduleID: String
    /// Kept when the schedule is removed.
    public var scheduleName: String
    public var cause: Cause
    public var dueAt: Date
    public var startedAt: Date
    public var endedAt: Date?
    public var state: ScheduleRunState
    /// Why it ended this way (`ScheduleReason`); English code text, localized in the UI.
    public var reason: ScheduleReason?
    public var workspace: String?
    public var pane: String?
    public var account: String?

    public init(id: String, scheduleID: String, scheduleName: String, cause: Cause, dueAt: Date, startedAt: Date,
                endedAt: Date? = nil, state: ScheduleRunState, reason: ScheduleReason? = nil, workspace: String? = nil,
                pane: String? = nil, account: String? = nil) {
        self.id = id
        self.scheduleID = scheduleID
        self.scheduleName = scheduleName
        self.cause = cause
        self.dueAt = dueAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.state = state
        self.reason = reason
        self.workspace = workspace
        self.pane = pane
        self.account = account
    }

    /// When it ended, else (still active) when it started: the order and age of the history.
    public var lastActivityAt: Date { endedAt ?? startedAt }

    private enum CodingKeys: String, CodingKey {
        case id, scheduleID, scheduleName, cause, dueAt, startedAt, endedAt, state, reason, workspace, pane, account
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lenientString(.id), let scheduleID = c.lenientString(.scheduleID),
              let state = try? c.decode(ScheduleRunState.self, forKey: .state),
              let dueAt = c.lenientDate(.dueAt) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "incomplete run")
        }
        self.id = id
        self.scheduleID = scheduleID
        scheduleName = c.lenientString(.scheduleName) ?? scheduleID
        cause = (try? c.decode(Cause.self, forKey: .cause)) ?? .scheduled
        self.dueAt = dueAt
        startedAt = c.lenientDate(.startedAt) ?? dueAt
        endedAt = c.lenientDate(.endedAt)
        self.state = state
        // An unknown code from a newer cmds is kept as text-less `other`.
        reason = c.lenientString(.reason).map { ScheduleReason(rawValue: $0) ?? .other }
        workspace = c.lenientString(.workspace)
        pane = c.lenientString(.pane)
        account = c.lenientString(.account)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(scheduleID, forKey: .scheduleID)
        try c.encode(scheduleName, forKey: .scheduleName)
        try c.encode(cause, forKey: .cause)
        try c.encode(dueAt.timeIntervalSince1970, forKey: .dueAt)
        try c.encode(startedAt.timeIntervalSince1970, forKey: .startedAt)
        try c.encodeIfPresent(endedAt?.timeIntervalSince1970, forKey: .endedAt)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(reason?.rawValue, forKey: .reason)
        try c.encodeIfPresent(workspace, forKey: .workspace)
        try c.encodeIfPresent(pane, forKey: .pane)
        try c.encodeIfPresent(account, forKey: .account)
    }
}

/// Why a run ended as it did. The raw value is stored and sent by the API; `english` is the CLI's text, the app
/// localizes its own.
public enum ScheduleReason: String, Codable, CaseIterable, Sendable {
    // Succeeded
    /// Claude Code started working on the prompt.
    case confirmed
    /// The prompt was sent but Claude Code was not seen working within `confirmTimeout`.
    case unconfirmed
    /// The command was typed (no prompt).
    case commandTyped
    /// The workspace was opened (no command).
    case workspaceOpened
    // Skipped
    case previousRunActive
    case tooManyRuns
    case paneInUse
    case allAccountsLimited
    case agentRunning
    case otherProgram
    case agentNotRunning
    case differentSession
    case movedToOtherAccount
    case notClaude
    // Failed
    case accountRemoved
    case accountStillLimited
    case paneClosed
    case shellNotReady
    case agentDidNotStart
    case agentBusy
    case sessionNotFound
    case folderMissing
    case invalidSchedule
    case resumeNotPossible
    // Missed / cancelled
    case missed
    case cancelledByUser
    case scheduleRemoved
    case appQuit
    /// A code this cmds does not know (from a newer version).
    case other

    public var english: String {
        switch self {
        case .confirmed: return "Claude Code started working on the prompt"
        case .unconfirmed: return "the prompt was sent, but Claude Code was not seen working"
        case .commandTyped: return "the command was typed"
        case .workspaceOpened: return "the workspace was opened"
        case .previousRunActive: return "the previous run was still active"
        case .tooManyRuns: return "too many runs were active"
        case .paneInUse: return "another run was using the pane"
        case .allAccountsLimited: return "every account has hit its limit"
        case .agentRunning: return "an agent was running in the pane"
        case .otherProgram: return "the pane was running another program"
        case .agentNotRunning: return "Claude Code was no longer running in the pane"
        case .differentSession: return "the pane was running a different session"
        case .movedToOtherAccount: return "the session had moved to another account"
        case .notClaude: return "the agent in the pane is not Claude Code"
        case .accountRemoved: return "the account was removed"
        case .accountStillLimited: return "the account was still limited"
        case .paneClosed: return "the pane was closed"
        case .shellNotReady: return "the shell prompt did not become ready"
        case .agentDidNotStart: return "Claude Code did not start"
        case .agentBusy: return "Claude Code stayed busy"
        case .sessionNotFound: return "no pane holds the session and its folder is not known"
        case .folderMissing: return "the folder does not exist"
        case .invalidSchedule: return "the schedule is not valid any more"
        case .resumeNotPossible: return "the session cannot be resumed"
        case .missed: return "the Mac was asleep or cmds was not running"
        case .cancelledByUser: return "cancelled"
        case .scheduleRemoved: return "the schedule was removed"
        case .appQuit: return "cmds quit during the run"
        case .other: return "unknown reason"
        }
    }
}

// MARK: - Limits and ids

public enum ScheduleLimits {
    public static let maxSchedules = 50
    public static let maxNameLength = 64
    public static let maxTimesPerDay = 24
    /// Times of a weekly rule are at least this far apart (also across midnight).
    public static let minTimeGap: TimeInterval = 5 * 60
    public static let maxDelay: TimeInterval = 3600
    public static let defaultDelay: TimeInterval = 60
    /// A late policy of a minute to a week.
    public static let minLateWindow: TimeInterval = 60
    public static let maxLateWindow: TimeInterval = 7 * 86400
    public static let maxActiveRuns = 5
    public static let maxPromptBytes = 8 * 1024
    public static let maxCommandBytes = 1024
    public static let maxTitleLength = 64
    /// A folder path (`StartWorkspace.cwd`, `ContinueSession.cwd`), in characters.
    public static let maxPathLength = 1024
    /// History: per schedule, in total, and age.
    public static let maxRunsPerSchedule = 50
    public static let maxRuns = 300
    /// `schedule.history` without a limit.
    public static let defaultHistoryLimit = 20
    public static let runRetention: TimeInterval = 90 * 86400
}

public enum ScheduleIDs {
    public static let schedulePrefix = "s"
    public static let runPrefix = "r"

    /// `prefix` + 8 random lowercase hex digits, not in `taken`.
    public static func make(prefix: String, taken: Set<String> = []) -> String {
        while true {
            let id = prefix + String(format: "%08x", UInt32.random(in: 0...UInt32.max))
            if !taken.contains(id) { return id }
        }
    }

    public static func isValid(_ id: String, prefix: String) -> Bool {
        guard id.hasPrefix(prefix) else { return false }
        let hex = id.dropFirst(prefix.count)
        return hex.count == 8 && hex.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }
}
