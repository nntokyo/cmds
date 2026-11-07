import Foundation

// The Mac's schedules on the phone, read only (`SyncFeature.schedules`, phase 3 of #45; docs/internals/sync-protocol.md
// "Schedules"). The summary is built here from the runner's list, so what reaches the phone is decided in one tested
// place: never a prompt, a command, the text of a `sendText`, a folder or a session id.

/// A schedule as the phone shows it.
public struct SyncScheduleSummary: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    /// The trigger (its times, weekdays, account name and delay). Nil when this phone does not know its type (a newer
    /// Mac): the phone shows the schedule without it.
    public var trigger: ScheduleTrigger?
    public var action: SyncScheduleAction
    /// The next firing; nil when the schedule is off or has none.
    public var nextFireAt: Date?
    /// The run in progress, if any.
    public var activeRun: ScheduleRun?
    /// The latest ended run, if any.
    public var lastRun: ScheduleRun?

    public init(id: String, name: String, enabled: Bool, trigger: ScheduleTrigger?, action: SyncScheduleAction,
                nextFireAt: Date? = nil, activeRun: ScheduleRun? = nil, lastRun: ScheduleRun? = nil) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.trigger = trigger
        self.action = action
        self.nextFireAt = nextFireAt
        self.activeRun = activeRun
        self.lastRun = lastRun
    }

    /// The summary of a schedule from the runner's list (`schedule.list` entry).
    public init(_ entry: ScheduleListEntry) {
        let schedule = entry.schedule
        self.init(id: schedule.id, name: schedule.name, enabled: schedule.enabled, trigger: schedule.trigger,
                  action: SyncScheduleAction(schedule.action), nextFireAt: entry.nextFireAt,
                  activeRun: entry.activeRun, lastRun: entry.lastRun)
    }

    private enum CodingKeys: String, CodingKey { case id, name, enabled, trigger, action, nextFireAt, activeRun, lastRun }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lenientString(.id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "schedule without id")
        }
        self.id = id
        name = c.lenientString(.name) ?? id
        enabled = c.lenientBool(.enabled) ?? false
        trigger = try? c.decodeIfPresent(ScheduleTrigger.self, forKey: .trigger)
        action = (try? c.decodeIfPresent(SyncScheduleAction.self, forKey: .action)) ?? SyncScheduleAction(type: "")
        nextFireAt = c.lenientDate(.nextFireAt)
        activeRun = try? c.decodeIfPresent(ScheduleRun.self, forKey: .activeRun)
        lastRun = try? c.decodeIfPresent(ScheduleRun.self, forKey: .lastRun)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(trigger, forKey: .trigger)
        try c.encode(action, forKey: .action)
        try c.encodeIfPresent(nextFireAt?.timeIntervalSince1970, forKey: .nextFireAt)
        try c.encodeIfPresent(activeRun, forKey: .activeRun)
        try c.encodeIfPresent(lastRun, forKey: .lastRun)
    }
}

/// What a schedule does, without its contents: the kind of action, the agent of a `continueSession` and where a
/// `sendText` goes. No prompt, command, text, folder, title, target or session id.
public struct SyncScheduleAction: Codable, Equatable, Sendable {
    /// `startWorkspace`, `continueSession`, `sendText`, or a type of a newer Mac (shown without a description).
    public var type: String
    /// `continueSession`: `claude` or `codex`.
    public var agent: AgentKind?
    /// `sendText`: `shell` or `agent`.
    public var to: SendText.Destination?

    public init(type: String, agent: AgentKind? = nil, to: SendText.Destination? = nil) {
        self.type = type
        self.agent = agent
        self.to = to
    }

    public init(_ action: ScheduleAction) {
        switch action {
        case .startWorkspace: self.init(type: action.type)
        case .continueSession(let session): self.init(type: action.type, agent: session.agent)
        case .sendText(let send): self.init(type: action.type, to: send.to)
        }
    }

    private enum CodingKeys: String, CodingKey { case type, agent, to }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenientString(.type) ?? ""
        agent = try? c.decodeIfPresent(AgentKind.self, forKey: .agent)
        to = try? c.decodeIfPresent(SendText.Destination.self, forKey: .to)
    }
}

/// Building and pacing the `schedules` message.
public enum SyncSchedules {
    /// Runs sent, newest first (the Mac keeps up to `ScheduleLimits.maxRuns`).
    public static let maxRuns = 30
    /// Least time between two `schedules` messages caused by changes.
    public static let interval: TimeInterval = 1

    /// The phone announced the feature in `hello.features`; older phones never get the message.
    public static func isWanted(by hello: ClientMessage.Hello) -> Bool {
        hello.features?.contains(SyncFeature.schedules) == true
    }

    /// The message from the runner's list and its runs (active ones first, then the history, newest first).
    public static func message(list: ScheduleList, runs: [ScheduleRun]) -> ServerMessage.Schedules {
        ServerMessage.Schedules(schedules: list.schedules.map(SyncScheduleSummary.init),
                                runs: Array(runs.prefix(maxRuns)), readOnly: list.readOnly ? true : nil)
    }

    /// How long a change waits before the next message goes out, so that at most one is sent per `interval`.
    public static func delay(lastSentAt: Date?, now: Date = Date()) -> TimeInterval {
        guard let lastSentAt else { return 0 }
        return min(interval, max(0, interval - now.timeIntervalSince(lastSentAt)))
    }
}

extension ServerMessage {
    /// The Mac's schedules and their recent runs (`SyncFeature.schedules`): sent after `welcome` and `state`, and on
    /// change at most once per `SyncSchedules.interval`, only to phones that announced the feature. Read only: there
    /// is no message to change or run a schedule.
    public struct Schedules: Codable, Equatable, Sendable {
        /// In the Mac's order.
        public var schedules: [SyncScheduleSummary]
        /// Recent runs, newest first (runs in progress first), at most `SyncSchedules.maxRuns`.
        public var runs: [ScheduleRun]
        /// The Mac's schedule files were made by a newer cmds (or could not be read): shown there, never run.
        public var readOnly: Bool?

        public init(schedules: [SyncScheduleSummary], runs: [ScheduleRun], readOnly: Bool? = nil) {
            self.schedules = schedules
            self.runs = runs
            self.readOnly = readOnly
        }

        private enum CodingKeys: String, CodingKey { case schedules, runs, readOnly }

        /// Lenient: an entry this phone cannot read is dropped, not the whole message.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let schedules = (try? c.decodeIfPresent([JSONValue].self, forKey: .schedules)) ?? []
            self.schedules = schedules.compactMap { try? $0.decode(SyncScheduleSummary.self) }
            let runs = (try? c.decodeIfPresent([JSONValue].self, forKey: .runs)) ?? []
            self.runs = runs.compactMap { try? $0.decode(ScheduleRun.self) }
            readOnly = c.lenientBool(.readOnly)
        }
    }
}
