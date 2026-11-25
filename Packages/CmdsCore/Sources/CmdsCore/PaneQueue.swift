import Foundation

/// Instructions kept for a pane whose agent is working, typed in when it is free (`cmds queue`, API `queue.*`;
/// docs/guide/queue.md). The app's PaneQueueRunner looks at the pane on every tick and does what
/// `PaneQueueTiming.step` says, which asks the same rules as a schedule run (`ScheduleRunTiming`): never into a
/// working agent, a question, a choice, another program, or an input box that holds text a person typed.
///
/// - One instruction at a time per pane, oldest first; each is typed once and then leaves the queue.
/// - The pane is named by its tag (`ScheduleIDs.paneTagPrefix`, saved with the session), so the queue finds it again
///   after cmds restarts. The file is `pane-queue.json` in the support directory, readable by the user only.
public struct PaneQueue: Codable, Equatable, Sendable {
    public static let fileName = "pane-queue.json"
    public static let currentVersion = 1
    public static let idPrefix = "q"
    /// Instructions waiting for one pane at most, and in all.
    public static let maxPerPane = 20
    public static let maxItems = 200
    /// Outcomes kept for `queue.list`.
    public static let maxRecent = 50

    public struct Item: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        /// The target pane's tag.
        public var paneTag: String
        public var text: String
        public var createdAt: Date
        /// The pane it was sent from (as it was then), if known.
        public var from: String?

        public init(id: String, paneTag: String, text: String, createdAt: Date, from: String? = nil) {
            self.id = id
            self.paneTag = paneTag
            self.text = text
            self.createdAt = createdAt
            self.from = from
        }
    }

    /// How an instruction left the queue.
    public enum Outcome: String, Codable, Sendable {
        /// Typed, and the agent was seen starting on it.
        case delivered
        /// Typed with Return; the agent was not seen starting within `ScheduleRunTiming.confirmTimeout`.
        case unconfirmed
        /// Pasted, but the agent left the foreground before Return: nothing more was typed.
        case failed
        case cancelled
    }

    public struct Ended: Codable, Equatable, Sendable {
        public var id: String
        public var paneTag: String
        public var outcome: Outcome
        public var createdAt: Date
        public var endedAt: Date

        public init(id: String, paneTag: String, outcome: Outcome, createdAt: Date, endedAt: Date) {
            self.id = id
            self.paneTag = paneTag
            self.outcome = outcome
            self.createdAt = createdAt
            self.endedAt = endedAt
        }
    }

    public enum Problem: Error, Equatable, Sendable {
        case emptyText
        case textTooLong
        case controlCharacters
        case paneFull
        case queueFull

        public var message: String {
            switch self {
            case .emptyText: return "the text is empty"
            case .textTooLong: return "the text is longer than \(ScheduleLimits.maxPromptBytes) bytes"
            case .controlCharacters: return "the text has control characters (only line breaks and tabs are allowed)"
            case .paneFull: return "\(PaneQueue.maxPerPane) instructions already wait for this pane"
            case .queueFull: return "\(PaneQueue.maxItems) instructions already wait"
            }
        }
    }

    public var version = PaneQueue.currentVersion
    /// Waiting instructions, oldest first.
    public private(set) var items: [Item] = []
    /// Ended instructions, newest first (never their text).
    public private(set) var recent: [Ended] = []

    public init() {}

    public static func url(supportDirectory: URL = CmdsEnv.supportDirectoryURL()) -> URL {
        supportDirectory.appendingPathComponent(fileName)
    }

    /// Why `text` cannot be queued; nil when it can. The text is typed as it is, then Return.
    public static func problem(of text: String) -> Problem? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyText }
        if text.utf8.count > ScheduleLimits.maxPromptBytes { return .textTooLong }
        let allowed: Set<Unicode.Scalar> = ["\n", "\t"]
        if text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && !allowed.contains($0) }) {
            return .controlCharacters
        }
        return nil
    }

    @discardableResult
    public mutating func add(text: String, paneTag: String, from: String? = nil, now: Date) throws -> Item {
        if let problem = Self.problem(of: text) { throw problem }
        guard items.count < Self.maxItems else { throw Problem.queueFull }
        guard items.filter({ $0.paneTag == paneTag }).count < Self.maxPerPane else { throw Problem.paneFull }
        let id = ScheduleIDs.make(prefix: Self.idPrefix, taken: Set(items.map(\.id) + recent.map(\.id)))
        let item = Item(id: id, paneTag: paneTag, text: text, createdAt: now, from: from)
        items.append(item)
        return item
    }

    /// The instruction typed next into the pane with `paneTag`.
    public func head(of paneTag: String) -> Item? {
        items.first { $0.paneTag == paneTag }
    }

    /// 1 for the pane's next instruction, 2 for the one after it…; nil when `id` does not wait.
    public func position(of id: String) -> Int? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        return items.filter { $0.paneTag == item.paneTag }.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    /// Tags of the panes something waits for, in the order of their oldest instruction.
    public var paneTags: [String] {
        var seen = Set<String>()
        return items.map(\.paneTag).filter { seen.insert($0).inserted }
    }

    /// Takes `id` out of the queue and records how it ended. nil when it does not wait.
    @discardableResult
    public mutating func end(id: String, _ outcome: Outcome, now: Date) -> Item? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let item = items.remove(at: index)
        recent.insert(Ended(id: item.id, paneTag: item.paneTag, outcome: outcome, createdAt: item.createdAt, endedAt: now), at: 0)
        if recent.count > Self.maxRecent { recent.removeLast(recent.count - Self.maxRecent) }
        return item
    }

    public static func load(from url: URL) -> StoredFile.LoadResult<PaneQueue> {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return StoredFile.load(PaneQueue.self, from: url, decoder: decoder)
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Why a pane's next instruction is not typed yet (`queue.list`).
public enum PaneQueueHold: String, Codable, Sendable {
    /// The agent is working (or a subagent is, or its screen has not settled yet).
    case busy
    /// The agent asks for input or permission, or shows a choice or a dialog instead of its input box.
    case needsInput
    /// The agent's input box holds text a person typed.
    case typedInput
    /// A shell is in the foreground: no agent runs in the pane.
    case agentNotRunning
    /// Another program is in the foreground, or cmds cannot tell which agent runs.
    case otherProgram
    /// A schedule run uses the pane, an account switch is in progress or a resume is queued.
    case otherInput
    /// No pane has the tag now (closed, or not restored).
    case paneNotFound

    public var english: String {
        switch self {
        case .busy: return "the agent is working"
        case .needsInput: return "the agent asks for input or permission, or shows a dialog"
        case .typedInput: return "its input box holds typed text"
        case .agentNotRunning: return "no agent runs in the pane"
        case .otherProgram: return "another program runs in the pane"
        case .otherInput: return "a schedule run, account switch or resume is using the pane"
        case .paneNotFound: return "the pane is not open"
        }
    }
}

/// When a pane's next instruction is typed. Pure rules over `ScheduleRunTiming`; unlike a schedule run, an instruction
/// waits as long as it takes (it never fails for a busy agent) and stays when no agent runs in the pane.
public enum PaneQueueTiming {
    public enum Phase: Equatable, Sendable {
        /// Waiting for the agent to be free.
        case waiting
        /// Pasted; Return follows.
        case typing
        /// Return pressed; watching the agent start.
        case confirming
    }

    public enum Step: Equatable, Sendable {
        case hold(PaneQueueHold)
        /// Paste the text now.
        case paste
        /// Nothing to do on this tick.
        case wait
        /// Press Return now.
        case enter
        case end(PaneQueue.Outcome)
    }

    /// The next step for the pane's head instruction, in `phase` since `elapsed`.
    public static func step(phase: Phase, observation o: ScheduleRunTiming.Observation, elapsed: TimeInterval) -> Step {
        switch phase {
        case .waiting:
            guard o.paneExists else { return .hold(.paneNotFound) }
            // Elapsed 0: an instruction outlasts `ScheduleRunTiming.idleWait`.
            let step = ScheduleRunTiming.step(state: .waitingForAgent, observation: o, elapsed: 0,
                                              expect: ScheduleRunTiming.Expectation(agent: nil))
            return step == .paste ? .paste : .hold(hold(o))
        case .typing:
            switch ScheduleRunTiming.step(state: .typing, observation: o, elapsed: elapsed) {
            case .enter: return .enter
            case .fail: return .end(.failed)
            default: return .wait
            }
        case .confirming:
            switch ScheduleRunTiming.step(state: .confirming, observation: o, elapsed: elapsed) {
            case .succeed(let reason): return .end(reason == .confirmed ? .delivered : .unconfirmed)
            default: return .wait
            }
        }
    }

    /// Why nothing is pasted, most telling reason first.
    static func hold(_ o: ScheduleRunTiming.Observation) -> PaneQueueHold {
        guard o.foreground == .agent else {
            return o.foreground == .shell && !o.agentOnTerminal ? .agentNotRunning : .otherProgram
        }
        guard o.agent == .claude || o.agent == .codex else { return .otherProgram }
        if o.otherInputInProgress || o.accountSwitchInProgress || o.resumeQueued { return .otherInput }
        if o.activity == .busy || o.workingOnScreen || o.subagentRunning { return .busy }
        if o.activity == .needsInput || o.choiceOnScreen || o.inputBoxMissing { return .needsInput }
        if o.inputHasText { return .typedInput }
        return .busy
    }
}

/// Result of `queue.list` (`cmds queue list`).
public struct PaneQueueList: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        /// The pane now (nil when it is not open) and its workspace's title.
        public var pane: String?
        public var workspaceTitle: String?
        public var text: String
        /// ISO 8601.
        public var createdAt: String
        /// 1 = typed next into its pane.
        public var position: Int
        /// Why the pane's next instruction waits (`PaneQueueHold`); nil while it is being typed, and for the ones behind it.
        public var hold: PaneQueueHold?

        public init(id: String, pane: String?, workspaceTitle: String?, text: String, createdAt: String, position: Int,
                    hold: PaneQueueHold?) {
            self.id = id
            self.pane = pane
            self.workspaceTitle = workspaceTitle
            self.text = text
            self.createdAt = createdAt
            self.position = position
            self.hold = hold
        }
    }

    public struct Ended: Codable, Equatable, Sendable {
        public var id: String
        public var pane: String?
        public var outcome: PaneQueue.Outcome
        /// ISO 8601.
        public var endedAt: String

        public init(id: String, pane: String?, outcome: PaneQueue.Outcome, endedAt: String) {
            self.id = id
            self.pane = pane
            self.outcome = outcome
            self.endedAt = endedAt
        }
    }

    public var waiting: [Entry]
    public var recent: [Ended]

    public init(waiting: [Entry], recent: [Ended]) {
        self.waiting = waiting
        self.recent = recent
    }
}
