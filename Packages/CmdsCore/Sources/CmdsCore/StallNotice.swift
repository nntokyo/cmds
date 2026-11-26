import Foundation

/// Telling one pane about panes that are stuck (`cmds stall`, API `stall.*`; docs/guide/queue.md "Stalled panes").
///
/// Three kinds of stall are told, each in one line kept for the chosen pane (`PaneQueue`, typed in when its agent is
/// free): an agent that has asked for input or permission for some minutes, an instruction kept for a pane that
/// has not been typed in for some minutes, and an agent that finished its work and has waited at its prompt for
/// some minutes (nothing in progress, nothing asked: a department with nothing to do). cmds never answers the question itself. The line has a fixed form (pane,
/// state, minutes, kind of reason) and nothing from the pane's screen. Off until turned on. Pure rules; the app's
/// `StallNoticeRunner` looks at the panes and queues the lines.
public enum StallNotice {
    public static let defaultInputMinutes = 10
    public static let defaultQueueMinutes = 15
    public static let defaultIdleMinutes = 10
    /// 0 = idle agents are not told.
    public static let idleMinutesRange = 0...24 * 60
    /// A minute to a day.
    public static let minutesRange = 1...24 * 60
    /// A stall that lasts is told again after this long.
    public static let repeatInterval: TimeInterval = 60 * 60
    /// The check that falls on the hour may come a moment early (a timer's minute is not exact): it counts, or the
    /// line would wait for the next check and come after 61 minutes.
    public static let repeatSlack: TimeInterval = 30
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
        /// An agent with nothing in progress (waiting at its prompt) for this long is told; 0 = never.
        public var idleMinutes: Int

        public init(enabled: Bool = false, toTag: String? = nil, inputMinutes: Int = StallNotice.defaultInputMinutes,
                    queueMinutes: Int = StallNotice.defaultQueueMinutes, idleMinutes: Int = StallNotice.defaultIdleMinutes) {
            self.enabled = enabled
            self.toTag = toTag
            self.inputMinutes = inputMinutes
            self.queueMinutes = queueMinutes
            self.idleMinutes = idleMinutes
        }

        private enum CodingKeys: String, CodingKey { case enabled, toTag, inputMinutes, queueMinutes, idleMinutes }

        /// Lenient: a missing or odd field takes its default.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
            toTag = (try? c.decodeIfPresent(String.self, forKey: .toTag)).flatMap { $0.isEmpty ? nil : $0 }
            let input = (try? c.decodeIfPresent(Int.self, forKey: .inputMinutes)) ?? StallNotice.defaultInputMinutes
            inputMinutes = StallNotice.minutesRange.contains(input) ? input : StallNotice.defaultInputMinutes
            let queue = (try? c.decodeIfPresent(Int.self, forKey: .queueMinutes)) ?? StallNotice.defaultQueueMinutes
            queueMinutes = StallNotice.minutesRange.contains(queue) ? queue : StallNotice.defaultQueueMinutes
            let idle = (try? c.decodeIfPresent(Int.self, forKey: .idleMinutes)) ?? StallNotice.defaultIdleMinutes
            idleMinutes = StallNotice.idleMinutesRange.contains(idle) ? idle : StallNotice.defaultIdleMinutes
        }
    }

    public enum Kind: String, Codable, Equatable, Sendable {
        /// The agent asks for input or permission.
        case needsInput
        /// An instruction kept for the pane has not been typed in.
        case undelivered
        /// The agent finished and waits at its prompt: nothing in progress, nothing asked.
        case idle
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
        /// The agent has nothing in progress (kind `idle`).
        case idle

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

    /// An agent that asks for input, or one that waits at its prompt, as the app sees it now (`IdlePanes`): for how
    /// long nothing has been in progress.
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
    /// its instruction waits; an idle agent whose instruction is not typed in (text in its input box) is told as that
    /// instruction, not also as idle.
    public static func stalls(asking: [Asking], waiting: [Waiting], idle: [Asking] = [], settings: Settings,
                              toPane: String?) -> [Stall] {
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
        let undelivered = Set(found.filter { $0.kind == .undelivered }.compactMap(\.pane))
        for i in idle where settings.idleMinutes > 0 && i.pane != toPane && i.seconds >= settings.idleMinutes * 60 {
            guard !undelivered.contains(i.pane), !askingPanes.contains(i.pane) else { continue }
            found.append(Stall(pane: i.pane, kind: .idle, minutes: i.seconds / 60, reason: .idle,
                               key: "\(i.pane):\(Kind.idle.rawValue)"))
        }
        return found.sorted { ($0.minutes, $1.key) > ($1.minutes, $0.key) }
    }

    /// When each stall was last told (in memory: after a restart of cmds a lasting stall is told once more).
    public struct State: Equatable, Sendable {
        public var sentAt: [String: Date] = [:]

        public init() {}

        public mutating func sent(_ stall: Stall, at now: Date) {
            sentAt[stall.key] = now
        }
    }

    /// The stalls to tell now: those not told yet and those last told `repeatInterval` ago (`repeatSlack`). A stall that is over is
    /// forgotten, so the next one of the pane is told at once.
    public static func due(_ stalls: [Stall], state: inout State, now: Date) -> [Stall] {
        let keys = Set(stalls.map(\.key))
        state.sentAt = state.sentAt.filter { keys.contains($0.key) }
        return stalls.filter { stall in
            guard let last = state.sentAt[stall.key] else { return true }
            return now.timeIntervalSince(last) >= repeatInterval - repeatSlack
        }
    }

    /// The one line the chosen pane gets: the pane, the state, the minutes and the kind of reason, nothing else.
    /// In Japanese, like the battery line (`PowerNotice`).
    public static func line(_ stall: Stall) -> String {
        let state: String
        switch stall.kind {
        case .needsInput: state = "入力待ち"
        case .undelivered: state = "預けた指示が未達"
        case .idle: state = "待機中"
        }
        return "cmds 詰まり通知: ペイン \(stall.pane ?? "-") / \(state) / \(stall.minutes) 分 / 理由 \(stall.reason.rawValue)"
    }

    // MARK: List file

    public static let listFileName = "stalls.txt"

    /// The file the stalls are written to at every check while the notice is on: the pane that is told may be busy
    /// for an hour, and its line waits until it is free; the file can be read meanwhile (by a person, a status line or
    /// an agent's hook). Removed when the notice is turned off.
    public static func listURL(supportDirectory: URL = CmdsEnv.supportDirectoryURL()) -> URL {
        supportDirectory.appendingPathComponent(listFileName)
    }

    /// The file's text: when it was written (ISO 8601) and how many stalls there are, then one line per stall in the
    /// form of `line` (pane, state, minutes, kind of reason; nothing from a pane's screen).
    public static func listText(_ stalls: [Stall], now: Date) -> String {
        let head = "cmds stall \(ISO8601DateFormatter().string(from: now)) \(stalls.count)"
        return ([head] + stalls.map(line)).joined(separator: "\n") + "\n"
    }

    public static func writeList(_ stalls: [Stall], now: Date, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(listText(stalls, now: now).utf8).write(to: url, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
    /// Where the stalls are written at every check while the notice is on (`StallNotice.listURL`).
    public var listFile: String?

    public init(settings: StallNotice.Settings, toPane: String?, stalls: [StallNotice.Stall], lastSentAt: String? = nil,
                lastLines: Int? = nil, listFile: String? = nil) {
        self.listFile = listFile
        self.settings = settings
        self.toPane = toPane
        self.stalls = stalls
        self.lastSentAt = lastSentAt
        self.lastLines = lastLines
    }
}
