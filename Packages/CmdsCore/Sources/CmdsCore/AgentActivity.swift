import Foundation

/// What the coding agent in a pane (or a workspace) is doing, for the sidebar badge.
/// Derived from Claude Code hook events, status-line reports and the spinner glyph agents put in the terminal title
/// (docs/guide/workspaces-and-panes.md "Agent state").
public enum AgentActivity: String, Codable, Sendable, Comparable {
    /// No agent runs (it exited, or none was seen).
    case none
    /// The agent finished its turn and waits for the next prompt.
    case idle
    /// The agent is working.
    case busy
    /// The agent asked for input or permission.
    case needsInput

    private var rank: Int {
        switch self {
        case .none: return 0
        case .idle: return 1
        case .busy: return 2
        case .needsInput: return 3
        }
    }

    /// Workspace state = the most pressing pane state (needs input > busy > idle > none).
    public static func < (lhs: AgentActivity, rhs: AgentActivity) -> Bool { lhs.rank < rhs.rank }
}

/// Parses terminal titles set by coding agents. Claude Code titles its terminal `✳ <topic>` while idle and animates a
/// spinner glyph (`◐◑◒◓`, braille dots, `✢✶✻✽`) in front of the topic while working.
public enum AgentTitle {
    public enum Glyph: Equatable, Sendable {
        case busy
        case idle
    }

    public struct Parsed: Equatable, Sendable {
        /// The leading status glyph; nil when the title has none (a shell title, not an agent's).
        public var glyph: Glyph?
        /// The glyph character itself (a change with the same topic means the spinner animates).
        public var glyphCharacter: Character?
        /// The title without the glyph; nil without a glyph or when it is only the agent's name.
        public var topic: String?
    }

    static let busyGlyphs: Set<Character> = ["◐", "◑", "◒", "◓", "◴", "◵", "◶", "◷", "✢", "✶", "✻", "✽", "·", "⏳"]
    static let idleGlyphs: Set<Character> = ["✳"]
    /// Default titles that say nothing about the task.
    static let genericTopics: Set<String> = ["claude code", "claude", "codex"]

    public static func parse(_ title: String) -> Parsed {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return Parsed() }
        let glyph: Glyph?
        if idleGlyphs.contains(first) {
            glyph = .idle
        } else if busyGlyphs.contains(first) || isBraille(first) {
            glyph = .busy
        } else {
            return Parsed()
        }
        let rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        let topic = rest.isEmpty || genericTopics.contains(rest.lowercased()) ? nil : rest
        return Parsed(glyph: glyph, glyphCharacter: first, topic: topic)
    }

    private static func isBraille(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
        return (0x2801...0x28FF).contains(scalar.value)
    }
}

/// Everything the app knows about a pane's agent, with timestamps; `activity(at:)` picks the latest evidence.
public struct AgentSignals: Equatable, Sendable {
    public enum HookState: Equatable, Sendable {
        /// `Notification`: permission prompt or waiting for input.
        case needsInput
        /// `UserPromptSubmit`, `PreToolUse`, `PostToolUse`.
        case busy
        /// `Stop`.
        case finished
    }

    /// Spinner frames younger than this mean the agent is working right now.
    public static let animationWindow: TimeInterval = 4
    /// A status-line report this long after a notification/stop counts as "working again" (reports trail the event).
    public static let reportGrace: TimeInterval = 3
    /// Busy without any new evidence for this long (and no spinner in the title) falls back to idle
    /// (an interrupted turn sends no `Stop`).
    public static let busyTimeout: TimeInterval = 10 * 60
    /// Busy known only from status-line reports falls back to idle sooner (reports stop when the turn ends).
    public static let reportBusyTimeout: TimeInterval = 90

    /// Latest hook event and when it arrived.
    public var hook: HookState?
    public var hookAt: Date?
    /// Current title glyph and when the title last changed to/with a glyph.
    public var titleGlyph: AgentTitle.Glyph?
    public var titleChangedAt: Date?
    /// Last time the glyph changed while the topic stayed (spinner animation).
    public var titleAnimatedAt: Date?
    /// Last status-line report whose figures changed (cost, tokens, context): the agent made an API call.
    public var reportChangedAt: Date?
    /// The pane has agent usage (status line / Codex session) right now.
    public var hasUsage = false
    /// The agent process was seen exiting (or `SessionEnd`); older title and hook evidence no longer applies.
    public var endedAt: Date?

    public init() {}

    /// Evidence older than the agent's exit is ignored.
    private func valid(_ date: Date?) -> Date? {
        guard let date else { return nil }
        if let endedAt, date <= endedAt { return nil }
        return date
    }

    public func activity(at now: Date) -> AgentActivity {
        let titleAt = valid(titleChangedAt)
        let hookAt = valid(hookAt)
        let animatedAt = valid(titleAnimatedAt)
        let reportAt = valid(reportChangedAt)
        let titleGlyph = titleAt == nil ? nil : titleGlyph
        guard hasUsage || titleGlyph != nil || hookAt != nil else { return .none }

        // Latest evidence wins.
        var best: (date: Date, activity: AgentActivity, timeout: TimeInterval)?
        func consider(_ date: Date?, _ activity: AgentActivity, timeout: TimeInterval = Self.busyTimeout) {
            guard let date else { return }
            if best == nil || date >= best!.date { best = (date, activity, timeout) }
        }
        if let hook = self.hook, let hookAt {
            switch hook {
            case .needsInput: consider(hookAt, .needsInput)
            case .busy: consider(hookAt, .busy)
            case .finished: consider(hookAt, .idle)
            }
        }
        if let titleGlyph, let titleAt { consider(titleAt, titleGlyph == .busy ? .busy : .idle) }
        if let reportAt {
            // A report right after a notification/stop belongs to that turn.
            let settledAt = (hook == .needsInput || hook == .finished) ? hookAt : nil
            if settledAt.map({ reportAt.timeIntervalSince($0) > Self.reportGrace }) ?? true {
                consider(reportAt, .busy, timeout: Self.reportBusyTimeout)
            }
        }
        // A spinning title means working right now, unless a notification / stop came after the last frame. (Spinner
        // frames can include the idle glyph `✳`; once the frames stop, the glyph left in the title decides.)
        if let animatedAt, now.timeIntervalSince(animatedAt) < Self.animationWindow,
           hook == .busy || hookAt.map({ animatedAt > $0 }) ?? true {
            return .busy
        }
        guard let best else { return .idle }
        if best.activity == .busy, titleGlyph != .busy, now.timeIntervalSince(best.date) > best.timeout { return .idle }
        return best.activity
    }

    /// When the agent last showed it was working (to tell whether it resumed after a notification).
    public var lastBusyAt: Date? {
        var dates: [Date] = []
        if hook == .busy, let date = valid(hookAt) { dates.append(date) }
        if let date = valid(titleAnimatedAt) { dates.append(date) }
        if titleGlyph == .busy, let date = valid(titleChangedAt) { dates.append(date) }
        if let date = valid(reportChangedAt) { dates.append(date) }
        return dates.max()
    }
}
