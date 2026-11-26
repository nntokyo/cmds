import Foundation

/// Telling one pane about panes that are stuck (`cmds stall`, API `stall.*`; docs/guide/queue.md "Stalled panes").
///
/// Two kinds of stall are told, each in one line kept for the chosen pane (`PaneQueue`, typed in when its agent is
/// free): an agent that has asked for input or permission for some minutes, and an instruction kept for a pane that
/// has not been typed in for some minutes. cmds never answers the question itself. The line has a fixed form (pane,
/// state, minutes, kind of reason) and nothing from the pane's screen. Off until turned on. Pure rules; the app's
/// `StallNoticeRunner` looks at the panes and queues the lines.
public enum StallNotice {
    public static let defaultInputMinutes = 10
    public static let defaultQueueMinutes = 15
    /// A minute to a day.
    public static let minutesRange = 1...24 * 60
    /// A stall that lasts is told again after this long.
    public static let repeatInterval: TimeInterval = 60 * 60
    /// At most this many lines wait for the pane that is told (of `PaneQueue.maxPerPane`): the rest of its queue
    /// stays free for instructions and the battery line.
    public static let maxWaitingLines = 10
    public static let fileName = "stall-notice.json"
    /// `PaneQueue.Item.from` of the lines cmds itself queues.
    public static let queueSource = "cmds:stall"

    public struct Settings: Codable, Equatable, Sendable {
        public var enabled: Bool
        /// The tag (`cmds tag`) of the pane that is told; nil = none chosen yet.
        public var toTag: String?
        /// An agent asking for input for this long is told.
        public var inputMinutes: Int
        /// A kept instruction not typed in for this long is told.
        public var queueMinutes: Int

        public init(enabled: Bool = false, toTag: String? = nil, inputMinutes: Int = StallNotice.defaultInputMinutes,
                    queueMinutes: Int = StallNotice.defaultQueueMinutes) {
            self.enabled = enabled
            self.toTag = toTag
            self.inputMinutes = inputMinutes
            self.queueMinutes = queueMinutes
        }

        private enum CodingKeys: String, CodingKey { case enabled, toTag, inputMinutes, queueMinutes }

        /// Lenient: a missing or odd field takes its default.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
            toTag = (try? c.decodeIfPresent(String.self, forKey: .toTag)).flatMap { $0.isEmpty ? nil : $0 }
            let input = (try? c.decodeIfPresent(Int.self, forKey: .inputMinutes)) ?? StallNotice.defaultInputMinutes
            inputMinutes = StallNotice.minutesRange.contains(input) ? input : StallNotice.defaultInputMinutes
            let queue = (try? c.decodeIfPresent(Int.self, forKey: .queueMinutes)) ?? StallNotice.defaultQueueMinutes
            queueMinutes = StallNotice.minutesRange.contains(queue) ? queue : StallNotice.defaultQueueMinutes
        }
    }

    public enum Kind: String, Codable, Equatable, Sendable {
        /// The agent asks for input or permission.
        case needsInput
        /// An instruction kept for the pane has not been typed in.
        case undelivered
    }

    /// Why, as one of a fixed set of words (never text from the pane).
    public enum Reason: String, Codable, Equatable, Sendable, CaseIterable {
        case permissionOrQuestion = "permission-or-question"
        case busy
        case needsInput = "needs-input"
        case typedInput = "typed-input"
        case noAgent = "no-agent"
        case otherProgram = "other-program"
        case otherInput = "other-input"
        case paneClosed = "pane-closed"
        case unknown

        public init(hold: PaneQueueHold?) {
            switch hold {
            case .busy: self = .busy
            case .needsInput: self = .needsInput
            case .typedInput: self = .typedInput
            case .agentNotRunning: self = .noAgent
            case .otherProgram: self = .otherProgram
            case .otherInput: self = .otherInput
            case .paneNotFound: self = .paneClosed
            case nil: self = .unknown
            }
        }
    }

    public struct Stall: Codable, Equatable, Sendable {
        /// The pane's id ("p12"); nil when the pane is not open (an instruction kept for a closed pane).
        public var pane: String?
        public var kind: Kind
        public var minutes: Int
        public var reason: Reason
        /// What the stall is remembered by between checks: the pane and the kind.
        public var key: String

        public init(pane: String?, kind: Kind, minutes: Int, reason: Reason, key: String) {
            self.pane = pane
            self.kind = kind
            self.minutes = minutes
            self.reason = reason
            self.key = key
        }
    }

    /// An agent that asks for input, as the app sees it now (`IdlePanes`).
    public struct Asking: Equatable, Sendable {
        public var pane: String
        public var seconds: Int

        public init(pane: String, seconds: Int) {
            self.pane = pane
            self.seconds = seconds
        }
    }

    /// The first instruction waiting for a pane.
    public struct Waiting: Equatable, Sendable {
        /// nil = the pane is not open.
        public var pane: String?
        public var tag: String
        public var seconds: Int
        public var hold: PaneQueueHold?
        /// `PaneQueue.Item.from`.
        public var from: String?

        public init(pane: String?, tag: String, seconds: Int, hold: PaneQueueHold?, from: String? = nil) {
            self.pane = pane
            self.tag = tag
            self.seconds = seconds
            self.hold = hold
            self.from = from
        }
    }

    /// The stalls there are now, longest first. Never about the pane that is told (`toPane`, `toTag`), never about a
    /// line cmds queued itself, and one per pane: an agent that asks for input is told as that, not also as the reason
    /// its instruction waits.
    public static func stalls(asking: [Asking], waiting: [Waiting], settings: Settings, toPane: String?) -> [Stall] {
        var found: [Stall] = []
        var askingPanes = Set<String>()
        for a in asking where a.pane != toPane && a.seconds >= settings.inputMinutes * 60 {
            askingPanes.insert(a.pane)
            found.append(Stall(pane: a.pane, kind: .needsInput, minutes: a.seconds / 60, reason: .permissionOrQuestion,
                               key: "\(a.pane):\(Kind.needsInput.rawValue)"))
        }
        for w in waiting where w.seconds >= settings.queueMinutes * 60 {
            guard w.from != queueSource, w.tag != settings.toTag, w.pane == nil || w.pane != toPane else { continue }
            if let pane = w.pane, askingPanes.contains(pane), w.hold == .needsInput { continue }
            found.append(Stall(pane: w.pane, kind: .undelivered, minutes: w.seconds / 60, reason: Reason(hold: w.hold),
                               key: "\(w.pane ?? "tag:" + w.tag):\(Kind.undelivered.rawValue)"))
        }
        return found.sorted { ($0.minutes, $1.key) > ($1.minutes, $0.key) }
    }

    /// When each stall was last told (in memory: after a restart of cmds a lasting stall is told once more).
    public struct State: Equatable, Sendable {
        public var sentAt: [String: Date] = [:]
        /// By stall key: the id of its kept line (`PaneQueue.Item.id`), while that may still wait.
        public var lines: [String: String] = [:]

        public init() {}

        public mutating func sent(_ stall: Stall, at now: Date, line: String? = nil) {
            sentAt[stall.key] = now
            if let line { lines[stall.key] = line }
        }
    }

    /// The ids of the lines to take back: kept earlier, still waiting (`waiting`: the ids of the lines of cmds that
    /// wait), for a stall that is over. Lines that were typed in are forgotten.
    public static func stale(_ stalls: [Stall], state: inout State, waiting: Set<String>) -> [String] {
        let keys = Set(stalls.map(\.key))
        let still = state.lines.filter { waiting.contains($0.value) }
        state.lines = still.filter { keys.contains($0.key) }
        return still.filter { !keys.contains($0.key) }.map(\.value).sorted()
    }

    /// Of the stalls that are due, those a line is kept for now (after `stale`). Not one whose earlier line still
    /// waits: the pane that is told has not read it yet, so it counts as told now. And no more than leave
    /// `maxWaitingLines` waiting; the others are due again at the next check.
    public static func toKeep(_ due: [Stall], state: inout State, now: Date) -> [Stall] {
        var room = max(0, maxWaitingLines - state.lines.count)
        return due.filter { stall in
            if state.lines[stall.key] != nil {
                state.sentAt[stall.key] = now
                return false
            }
            guard room > 0 else { return false }
            room -= 1
            return true
        }
    }

    /// A change of the settings after which every stall is told anew and the lines still waiting are taken back:
    /// turned on or off, or another pane is told.
    public static func startsOver(from old: Settings, to new: Settings) -> Bool {
        old.enabled != new.enabled || old.toTag != new.toTag
    }

    /// The stalls to tell now: those not told yet and those last told `repeatInterval` ago. A stall that is over is
    /// forgotten, so the next one of the pane is told at once.
    public static func due(_ stalls: [Stall], state: inout State, now: Date) -> [Stall] {
        let keys = Set(stalls.map(\.key))
        state.sentAt = state.sentAt.filter { keys.contains($0.key) }
        return stalls.filter { stall in
            guard let last = state.sentAt[stall.key] else { return true }
            return now.timeIntervalSince(last) >= repeatInterval
        }
    }

    /// The one line the chosen pane gets: the pane, the state, the minutes and the kind of reason, nothing else.
    /// In Japanese, like the battery line (`PowerNotice`).
    public static func line(_ stall: Stall) -> String {
        let state: String
        switch stall.kind {
        case .needsInput: state = "入力待ち"
        case .undelivered: state = "預けた指示が未達"
        }
        return "cmds 詰まり通知: ペイン \(stall.pane ?? "-") / \(state) / \(stall.minutes) 分 / 理由 \(stall.reason.rawValue)"
    }

    // MARK: File

    public static func url(supportDirectory: URL = CmdsEnv.supportDirectoryURL()) -> URL {
        supportDirectory.appendingPathComponent(fileName)
    }

    /// The saved settings; the defaults (off) when there is no file or it cannot be read.
    public static func loadSettings(from url: URL) -> Settings {
        guard let data = try? Data(contentsOf: url) else { return Settings() }
        return (try? JSONDecoder().decode(Settings.self, from: data)) ?? Settings()
    }

    public static func save(_ settings: Settings, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(settings).write(to: url, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// `stall.status` / `stall.set` (`cmds stall`).
public struct StallNoticeStatus: Codable, Equatable, Sendable {
    public var settings: StallNotice.Settings
    /// The id of the pane that is told; nil when none is chosen or it is not open.
    public var toPane: String?
    /// The stalls there are now (also while the notice is off).
    public var stalls: [StallNotice.Stall]
    /// The last lines sent since cmds started: when (ISO 8601) and how many.
    public var lastSentAt: String?
    public var lastLines: Int?

    public init(settings: StallNotice.Settings, toPane: String?, stalls: [StallNotice.Stall], lastSentAt: String? = nil,
                lastLines: Int? = nil) {
        self.settings = settings
        self.toPane = toPane
        self.stalls = stalls
        self.lastSentAt = lastSentAt
        self.lastLines = lastLines
    }
}
