import Foundation

/// Telling the agents that the Mac runs on battery (`cmds power`, API `power.*`; docs/guide/queue.md "On battery").
///
/// When the Mac switches from the power adapter to its battery, and when the battery falls below a set level while
/// it is not charging, cmds keeps one line for every pane that runs an agent (`PaneQueue`, typed in when the agent
/// is free): wrap up, leave nothing half-applied, record the next step. A closed lid on battery stops every agent
/// mid-turn; the line gives them the minutes before that. Off until turned on. Pure rules; the app's
/// `PowerNoticeRunner` reads the power source and queues the lines.
public enum PowerNotice {
    public static let defaultBelowPercent = 25
    public static let belowRange = 5...95
    /// Above the level by this much (or on the adapter) before a second "low" line is sent.
    public static let rearmMargin = 5
    public static let fileName = "power-notice.json"
    /// `PaneQueue.Item.from` of the lines cmds itself queues.
    public static let queueSource = "cmds:power"

    /// What follows the reason in the line cmds sends. In Japanese, like the reason: the line is for the agents of
    /// the people cmds is made for, whatever the Mac's language (`cmds power notice --request` replaces it).
    public static let defaultRequest = "区切りをつけ、途中の反映を残さず、次の一手を 1 行で記録してください。"

    public struct Settings: Codable, Equatable, Sendable {
        public var enabled: Bool
        /// The "low" line is sent when the charge is below this, on battery.
        public var belowPercent: Int
        /// Replaces `defaultRequest` (one line).
        public var request: String?

        public init(enabled: Bool = false, belowPercent: Int = PowerNotice.defaultBelowPercent, request: String? = nil) {
            self.enabled = enabled
            self.belowPercent = belowPercent
            self.request = request
        }

        private enum CodingKeys: String, CodingKey { case enabled, belowPercent, request }

        /// Lenient: a missing or odd field takes its default.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
            let below = (try? c.decodeIfPresent(Int.self, forKey: .belowPercent)) ?? PowerNotice.defaultBelowPercent
            belowPercent = PowerNotice.belowRange.contains(below) ? below : PowerNotice.defaultBelowPercent
            request = (try? c.decodeIfPresent(String.self, forKey: .request)).flatMap(PowerNotice.oneLine)
        }
    }

    /// The Mac's power source as read now.
    public struct Power: Codable, Equatable, Sendable {
        public var onBattery: Bool
        /// Charge in percent; nil = no battery (a desktop Mac) or not known.
        public var percent: Int?

        public init(onBattery: Bool, percent: Int?) {
            self.onBattery = onBattery
            self.percent = percent
        }
    }

    public enum Event: String, Codable, Equatable, Sendable {
        /// The adapter was unplugged (or stopped supplying power).
        case onBattery
        /// On battery, the charge fell below the level (also when the adapter is unplugged below it).
        case low
    }

    /// What was seen and sent so far (in memory: after a restart of cmds a low battery is told once more).
    public struct State: Equatable, Sendable {
        public var last: Power?
        public var lowSent = false

        public init() {}
    }

    /// The event to tell the agents about now that the power source reads `current`; nil = nothing. One event per
    /// change (low wins over the switch), each once: the switch only on a change seen from the adapter to the battery
    /// (not at launch), low once until the Mac is back on the adapter or `rearmMargin` above the level.
    public static func event(current: Power, settings: Settings, state: inout State) -> Event? {
        let previous = state.last
        state.last = current
        guard current.onBattery else {
            state.lowSent = false
            return nil
        }
        let percent = current.percent
        if let percent, percent >= settings.belowPercent + rearmMargin { state.lowSent = false }
        guard settings.enabled else { return nil }
        if let percent, percent < settings.belowPercent, !state.lowSent {
            state.lowSent = true
            return .low
        }
        if let previous, !previous.onBattery { return .onBattery }
        return nil
    }

    /// The one line the agents get.
    public static func line(_ event: Event, power: Power, settings: Settings) -> String {
        let reason: String
        switch event {
        case .onBattery:
            reason = "この Mac の電源が電池に切り替わりました" + (power.percent.map { "（残り \($0)%）" } ?? "") + "。"
        case .low:
            reason = "この Mac の電池の残りが \(settings.belowPercent)% を下回りました（"
                + (power.percent.map { "残り \($0)%、" } ?? "") + "充電されていません）。"
        }
        return reason + (settings.request ?? defaultRequest)
    }

    /// `text` as one line (line breaks and tabs become spaces), nil when nothing is left; at most 500 characters.
    public static func oneLine(_ text: String) -> String? {
        let flat = text.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : String($0) }.joined()
        let trimmed = flat.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return trimmed.isEmpty ? nil : String(trimmed.prefix(500))
    }

    /// The panes that get the line: `candidates` in order, those that run an agent and have no line of cmds waiting
    /// already (a second change before the agent was free adds nothing).
    public static func targets(_ candidates: [Candidate]) -> [String] {
        candidates.filter { $0.runsAgent && !$0.hasPowerLineWaiting }.map(\.pane)
    }

    public struct Candidate: Equatable, Sendable {
        public var pane: String
        public var runsAgent: Bool
        public var hasPowerLineWaiting: Bool

        public init(pane: String, runsAgent: Bool, hasPowerLineWaiting: Bool) {
            self.pane = pane
            self.runsAgent = runsAgent
            self.hasPowerLineWaiting = hasPowerLineWaiting
        }
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

/// `power.status` / `power.set` (`cmds power`).
public struct PowerNoticeStatus: Codable, Equatable, Sendable {
    public var settings: PowerNotice.Settings
    /// nil = the power source could not be read.
    public var power: PowerNotice.Power?
    /// The last line sent since cmds started: which, when (ISO 8601) and to how many panes.
    public var lastEvent: PowerNotice.Event?
    public var lastSentAt: String?
    public var lastPanes: Int?

    public init(settings: PowerNotice.Settings, power: PowerNotice.Power?, lastEvent: PowerNotice.Event? = nil,
                lastSentAt: String? = nil, lastPanes: Int? = nil) {
        self.settings = settings
        self.power = power
        self.lastEvent = lastEvent
        self.lastSentAt = lastSentAt
        self.lastPanes = lastPanes
    }
}
