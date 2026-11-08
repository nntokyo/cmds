import Foundation

// Recent agent sessions (docs/guide/ai-agents.md "Recent sessions"): every Claude Code / Codex session cmds saw in
// any pane, kept after the agent exits or its pane closes, so File › Recent Agent Sessions can resume it later.

/// App-wide list of the agent sessions cmds saw, newest `lastSeen` first, one entry per agent + session id + host.
/// `agent-history.json` in the support directory: `{"version": 1, "sessions": [...]}`.
public struct AgentSessionHistory: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// Entries kept (the menu shows `AgentSessionHistory.shown` of them).
    public static let capacity = 20
    /// Entries in File › Recent Agent Sessions.
    public static let shown = 5

    public private(set) var sessions: [AgentSession]

    public init(sessions: [AgentSession] = []) {
        self.sessions = []
        for session in sessions { record(session) }
    }

    /// Same session: same agent, id and host (a session id on a server is another session than one on this Mac).
    public static func sameSession(_ a: AgentSession, _ b: AgentSession) -> Bool {
        a.agent == b.agent && a.sessionID == b.sessionID && a.host == b.host
    }

    /// Adds or updates the entry of `session`. The newer report's title, model and account win (title and model only
    /// when it has them); the directory stays the one the session was first seen in (where it resumes). Returns
    /// whether anything changed.
    @discardableResult
    public mutating func record(_ session: AgentSession) -> Bool {
        guard AgentResume.supports(session.agent), AgentResume.isValidSessionID(session.sessionID) else { return false }
        var entry = session
        if let index = sessions.firstIndex(where: { Self.sameSession($0, session) }) {
            let existing = sessions[index]
            if session.lastSeen >= existing.lastSeen {
                entry.cwd = existing.cwd ?? session.cwd
                entry.title = session.title ?? existing.title
                entry.model = session.model ?? existing.model
            } else {
                entry = existing
                entry.cwd = existing.cwd ?? session.cwd
                entry.title = existing.title ?? session.title
                entry.model = existing.model ?? session.model
            }
            guard entry != existing else { return false }
            sessions.remove(at: index)
        }
        let position = sessions.firstIndex { $0.lastSeen < entry.lastSeen } ?? sessions.count
        // A new session older than every entry of a full list (an update never moves down past its old place).
        guard position < Self.capacity else { return false }
        sessions.insert(entry, at: position)
        if sessions.count > Self.capacity { sessions.removeLast(sessions.count - Self.capacity) }
        return true
    }

    /// The `count` newest sessions.
    public func recent(_ count: Int = AgentSessionHistory.shown) -> [AgentSession] {
        Array(sessions.prefix(max(0, count)))
    }

    public mutating func removeAll() {
        sessions.removeAll()
    }

    private enum CodingKeys: String, CodingKey { case version, sessions }

    /// Lenient: entries that cannot be resumed (`AgentSession` refuses them) are dropped, not the whole file; the list
    /// is re-sorted, deduplicated and capped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decodeIfPresent([LossySession].self, forKey: .sessions)) ?? []
        self.init(sessions: raw.compactMap(\.value))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(sessions, forKey: .sessions)
    }
}

private struct LossySession: Decodable {
    var value: AgentSession?
    init(from decoder: Decoder) throws { value = try? AgentSession(from: decoder) }
}

/// `agent-history.json` in the support directory (`CMDS_SUPPORT_DIR` for an isolated instance). Loaded through
/// `StoredFile` (a damaged file is moved aside, never overwritten); written atomically, readable by the user only
/// (titles and directories).
public enum AgentSessionHistoryStore {
    public static let fileName = "agent-history.json"

    public static func url(supportDirectory: URL = CmdsEnv.supportDirectoryURL()) -> URL {
        supportDirectory.appendingPathComponent(fileName)
    }

    public struct Loaded {
        /// Empty when the file is missing or could not be read.
        public var history: AgentSessionHistory
        public var error: Error?
        /// Where an undecodable file was moved (kept).
        public var movedAside: URL?
        /// The file could not be read and is still in place: saving would overwrite it.
        public var saveBlocked: Bool { error != nil && movedAside == nil }
    }

    public static func load(from url: URL, now: Date = Date()) -> Loaded {
        switch StoredFile.load(AgentSessionHistory.self, from: url, now: now) {
        case .missing:
            return Loaded(history: AgentSessionHistory())
        case .loaded(let history):
            return Loaded(history: history)
        case .unreadable(let error, .success(let moved)):
            return Loaded(history: AgentSessionHistory(), error: error, movedAside: moved)
        case .unreadable(let error, .failure):
            return Loaded(history: AgentSessionHistory(), error: error)
        }
    }

    public static func save(_ history: AgentSessionHistory, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(history).write(to: url, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// One session of `agent.history` (`cmds sessions --recent`).
public struct AgentHistoryEntry: Codable, Equatable, Sendable {
    public var session: AgentSession
    /// The pane holding the session now (running, offering or remembering it); nil when no pane does.
    public var pane: String?
    public var state: AgentSessionState?
    /// The command resuming types into a new pane's shell.
    public var command: String?

    public init(session: AgentSession, pane: String? = nil, state: AgentSessionState? = nil, command: String?) {
        self.session = session
        self.pane = pane
        self.state = state
        self.command = command
    }
}
