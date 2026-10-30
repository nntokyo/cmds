import Foundation

// Resuming AI agent sessions after cmds restarts (docs/AGENTS.md "Resuming sessions").
// The app remembers per terminal pane the agent session that ran there (`AgentSession`, saved in session.json),
// offers it again after a relaunch and, when asked, types the resume command into the pane's own shell.

/// The coding agent session last seen in a terminal pane. Only resumable agents (Claude Code, Codex) are kept.
public struct AgentSession: Codable, Equatable, Sendable {
    public var agent: AgentKind
    /// Claude Code: `session_id` of the status-line JSON; Codex: the rollout session id. Always passes
    /// `AgentResume.isValidSessionID`.
    public var sessionID: String
    /// Directory the agent was started in (on `host` for SSH panes); the resume command `cd`s there first.
    public var cwd: String?
    /// SSH panes: the server (the session lives there).
    public var host: String?
    /// Pane title while the agent ran (Claude Code sets it to the conversation topic).
    public var title: String?
    public var model: String?
    /// Last time the agent reported (status line / session file).
    public var lastSeen: Date

    public init(agent: AgentKind, sessionID: String, cwd: String? = nil, host: String? = nil, title: String? = nil,
                model: String? = nil, lastSeen: Date = Date()) {
        self.agent = agent
        self.sessionID = sessionID
        self.cwd = cwd
        self.host = host
        self.title = title
        self.model = model
        self.lastSeen = lastSeen
    }

    private enum CodingKeys: String, CodingKey {
        case agent, sessionID, cwd, host, title, model, lastSeen
    }

    /// Fails for records that cannot be resumed (unknown agent, malformed id), so callers can drop them.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent = (try? c.decode(AgentKind.self, forKey: .agent)) ?? .other
        guard AgentResume.supports(agent) else {
            throw DecodingError.dataCorruptedError(forKey: .agent, in: c, debugDescription: "not a resumable agent")
        }
        guard let id = c.lenientString(.sessionID), AgentResume.isValidSessionID(id) else {
            throw DecodingError.dataCorruptedError(forKey: .sessionID, in: c, debugDescription: "invalid session id")
        }
        sessionID = id
        cwd = c.lenientString(.cwd)
        host = c.lenientString(.host)
        title = c.lenientString(.title)
        model = c.lenientString(.model)
        lastSeen = c.lenientDate(.lastSeen) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(agent, forKey: .agent)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(host, forKey: .host)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encode(lastSeen.timeIntervalSince1970, forKey: .lastSeen)
    }

    /// `Claude Code session "Fix login" (Opus, 3 h ago)`-style one-liner for banners and the CLI.
    public func summary(now: Date = Date()) -> String {
        var details: [String] = []
        if let model, !model.isEmpty { details.append(model) }
        details.append(AgentResume.relative(lastSeen, now: now))
        var text = "\(AgentResume.displayName(agent)) session"
        if let title = AgentResume.cleanTitle(title) { text += " “\(title)”" }
        return text + " (\(details.joined(separator: ", ")))"
    }
}

/// Resume setting: View › Resume Agent Sessions on Launch.
public enum AgentResumeMode: String, Codable, Sendable, CaseIterable {
    /// Show a banner with Resume / Dismiss (default).
    case ask
    /// Resume automatically once the pane's shell prompt is ready.
    case always
    /// Forget remembered sessions on launch.
    case never
}

/// State of a remembered session in `agent.sessions`.
public enum AgentSessionState: String, Codable, Sendable {
    /// From the previous run: offered (banner), not resumed yet.
    case offered
    /// Resume requested; waiting for the shell prompt (SSH panes: for the connection) before typing.
    case waiting
    /// The agent is running in the pane (this is its current session).
    case running
    /// Resumed earlier in this run.
    case resumed
}

/// One pane's remembered session (`agent.sessions`).
public struct AgentSessionEntry: Codable, Equatable, Sendable {
    public var workspace: String
    public var pane: String
    public var state: AgentSessionState
    public var session: AgentSession
    /// The command that resuming types into the pane.
    public var command: String?

    public init(workspace: String, pane: String, state: AgentSessionState, session: AgentSession, command: String?) {
        self.workspace = workspace
        self.pane = pane
        self.state = state
        self.session = session
        self.command = command
    }
}

public struct AgentSessionList: Codable, Equatable, Sendable {
    public var mode: AgentResumeMode
    public var sessions: [AgentSessionEntry]

    public init(mode: AgentResumeMode, sessions: [AgentSessionEntry]) {
        self.mode = mode
        self.sessions = sessions
    }
}

/// Result of `agent.resume`.
public struct AgentResumeResult: Codable, Equatable, Sendable {
    public struct Skipped: Codable, Equatable, Sendable {
        public var pane: String
        public var reason: String
        public init(pane: String, reason: String) {
            self.pane = pane
            self.reason = reason
        }
    }

    /// Panes that will get the resume command once their shell prompt is ready (or got it already).
    public var queued: [String]
    public var skipped: [Skipped]

    public init(queued: [String] = [], skipped: [Skipped] = []) {
        self.queued = queued
        self.skipped = skipped
    }
}

/// Building and checking resume commands. Everything typed into a shell comes from here.
public enum AgentResume {
    public static func supports(_ agent: AgentKind) -> Bool { agent == .claude || agent == .codex }

    public static func displayName(_ agent: AgentKind) -> String {
        switch agent {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .other: return "Agent"
        }
    }

    /// Session ids are typed into a shell, so only plain ids: letters, digits, `-`, `_`, `.`, 1–128 characters,
    /// not starting with `-` or `.` (Claude Code and Codex use UUIDs).
    public static func isValidSessionID(_ id: String) -> Bool {
        guard (1...128).contains(id.count), let first = id.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first), first.isASCII else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return id.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// The command line typed into the pane's shell (without the trailing Return):
    /// `cd '<cwd>' && claude --resume <id>` / `cd '<cwd>' && codex resume <id>`.
    /// nil when the session cannot be resumed safely (unsupported agent, invalid id).
    /// A cwd that cannot be quoted for every shell (quotes, backslashes, control characters) is left out.
    public static func command(for session: AgentSession) -> String? {
        guard isValidSessionID(session.sessionID) else { return nil }
        let resume: String
        switch session.agent {
        case .claude: resume = "claude --resume \(session.sessionID)"
        case .codex: resume = "codex resume \(session.sessionID)"
        case .other: return nil
        }
        guard let cwd = session.cwd, let quoted = quotedPath(cwd) else { return resume }
        return "cd \(quoted) && \(resume)"
    }

    /// Single-quoted for sh/bash/zsh/fish/tcsh alike: only absolute or `~/…` paths without `'`, `\`, `!` or
    /// control characters (those would need shell-specific escaping). `~/x` becomes `~/'x'` so the tilde expands.
    public static func quotedPath(_ path: String) -> String? {
        guard !path.isEmpty, path.count <= 1024,
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || "'\\!".unicodeScalars.contains($0) })
        else { return nil }
        if path == "~" { return "~" }
        if path.hasPrefix("~/") { return "~/'\(path.dropFirst(2))'" }
        guard path.hasPrefix("/") else { return nil }
        return "'\(path)'"
    }

    /// The last non-empty screen line looks like a shell prompt waiting for a command (used for SSH panes, whose
    /// remote shell cannot be seen as a process): ends in `$ # % > ❯ ➜ λ »` (optionally followed by a space) and
    /// is not asking for a password, passphrase or confirmation.
    public static func looksLikePrompt(screen: String) -> Bool {
        guard let line = screen.split(separator: "\n", omittingEmptySubsequences: true)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return false }
        let lower = line.lowercased()
        for word in ["password", "passphrase", "passcode", "verification code", "(yes/no", "[y/n]", "(y/n)"]
            where lower.contains(word) { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return false }
        return "$#%>❯➜λ»".contains(last)
    }

    /// Terminal titles are often decorated (`✳ Fix login`, spinner glyphs); returns the readable part, nil when empty
    /// or just the default title.
    public static func cleanTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "✳✻✽✶✢·*⠁⠂⠄⡀⢀⠠⠐⠈⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")))
        guard !trimmed.isEmpty, trimmed != "Terminal", trimmed.lowercased() != "claude code" else { return nil }
        return String(trimmed.prefix(80))
    }

    /// `just now`, `5 min ago`, `3 h ago`, `2 d ago`.
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) h ago" }
        return "\(Int(seconds / 86400)) d ago"
    }
}
