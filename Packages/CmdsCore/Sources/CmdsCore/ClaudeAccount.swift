import Foundation

// Several Claude Code accounts of the user (docs/guide/ai-agents.md "Several Claude accounts").
// An account is a name and a Claude Code config directory (`CLAUDE_CONFIG_DIR`) the user signed in to once with
// `claude` → `/login`. cmds keeps only the name, the path and the last limit it saw; it never reads, copies or
// stores what Claude Code keeps in that directory (credentials, settings, transcripts).

/// One Claude Code account: a name and its config directory.
public struct ClaudeAccount: Codable, Equatable, Sendable {
    public var name: String
    /// As the user gave it: absolute or `~/…` (`ClaudeAccounts.expandedPath` for use).
    public var configDir: String
    /// The last usage / rate limit seen for this account; kept after it has reset (`ClaudeAccountLimit.isActive`).
    public var limit: ClaudeAccountLimit?

    public init(name: String, configDir: String, limit: ClaudeAccountLimit? = nil) {
        self.name = name
        self.configDir = configDir
        self.limit = limit
    }

    public func isLimited(at now: Date = Date()) -> Bool { limit?.isActive(at: now) ?? false }
}

/// How an account's limit was recognised.
public enum ClaudeLimitKind: String, Codable, Sendable {
    /// Claude Code's "You've hit your … limit · resets …" (5-hour / weekly / Opus limit) or a status-line window
    /// at 100 %.
    case usageLimit
    /// An API rate-limit error (HTTP 429, `rate_limit_error`).
    case rateLimit
}

/// A limit seen for an account and when it ends.
public struct ClaudeAccountLimit: Codable, Equatable, Sendable {
    public var kind: ClaudeLimitKind
    /// When the account can be used again. Estimated (`estimated`) when the message had no time.
    public var resetsAt: Date
    public var estimated: Bool
    public var detectedAt: Date
    /// The line that showed it (trimmed, at most 200 characters), for the user.
    public var message: String?

    public init(kind: ClaudeLimitKind, resetsAt: Date, estimated: Bool = false, detectedAt: Date = Date(), message: String? = nil) {
        self.kind = kind
        self.resetsAt = resetsAt
        self.estimated = estimated
        self.detectedAt = detectedAt
        self.message = message.map { String($0.prefix(200)) }
    }

    public func isActive(at now: Date = Date()) -> Bool { resetsAt > now }

    private enum CodingKeys: String, CodingKey { case kind, resetsAt, estimated, detectedAt, message }

    /// Dates are epoch seconds (as in `AgentUsage`), also in the API.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(ClaudeLimitKind.self, forKey: .kind)) ?? .usageLimit
        guard let resetsAt = c.lenientDate(.resetsAt) else {
            throw DecodingError.dataCorruptedError(forKey: .resetsAt, in: c, debugDescription: "missing reset time")
        }
        self.resetsAt = resetsAt
        estimated = c.lenientBool(.estimated) ?? false
        detectedAt = c.lenientDate(.detectedAt) ?? resetsAt
        message = c.lenientString(.message).map { String($0.prefix(200)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(resetsAt.timeIntervalSince1970, forKey: .resetsAt)
        try c.encode(estimated, forKey: .estimated)
        try c.encode(detectedAt.timeIntervalSince1970, forKey: .detectedAt)
        try c.encodeIfPresent(message, forKey: .message)
    }
}

/// What cmds stores about the accounts (`claude-accounts.json` in the support directory).
public struct ClaudeAccountSettings: Codable, Equatable, Sendable {
    /// In the user's order: switching and `--account auto` take the first one without an active limit.
    public var accounts: [ClaudeAccount]
    /// Switch a pane to the next account by itself (at its idle prompt) instead of asking.
    public var autoSwitch: Bool

    public init(accounts: [ClaudeAccount] = [], autoSwitch: Bool = false) {
        self.accounts = accounts
        self.autoSwitch = autoSwitch
    }

    private enum CodingKeys: String, CodingKey { case accounts, autoSwitch }

    /// Tolerant: accounts that cannot be decoded or are invalid are dropped (names stay unique).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decode([Lossy<ClaudeAccount>].self, forKey: .accounts)) ?? []
        var seen = Set<String>()
        accounts = raw.compactMap(\.value).filter {
            ClaudeAccounts.nameProblem($0.name) == nil && ClaudeAccounts.pathProblem($0.configDir) == nil
                && seen.insert($0.name.lowercased()).inserted
        }
        autoSwitch = c.lenientBool(.autoSwitch) ?? false
    }

    public func account(named name: String) -> ClaudeAccount? {
        accounts.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

private struct Lossy<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// Rules for accounts: names, paths, matching a config dir to an account and choosing the next one.
public enum ClaudeAccounts {
    /// Claude Code's default config directory when `CLAUDE_CONFIG_DIR` is not set.
    public static let defaultConfigDir = "~/.claude"
    /// `--account auto` (`cmds new`, `cmds split`): the first account without an active limit.
    public static let automatic = "auto"
    public static let maxAccounts = 20

    /// Names are shown in the sidebar and typed on the command line: letters, digits, `-`, `_`, `.`, `@`, 1–32
    /// characters, starting with a letter or digit, not `auto`. nil when fine.
    public static func nameProblem(_ name: String) -> String? {
        guard (1...32).contains(name.count) else { return "the name must be 1 to 32 characters" }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.@")
        guard name.unicodeScalars.allSatisfy(allowed.contains),
              let first = name.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) else {
            return "the name may contain letters, digits, - _ . @ and must start with a letter or digit"
        }
        guard name.lowercased() != automatic else { return "\"auto\" is reserved for --account auto" }
        return nil
    }

    /// The directory is typed into a shell (`env CLAUDE_CONFIG_DIR='…'`), so it must be absolute or `~/…` and
    /// quotable for every shell (`AgentResume.quotedPath`). nil when fine.
    public static func pathProblem(_ path: String) -> String? {
        guard path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") else {
            return "the config directory must be an absolute path or start with ~/"
        }
        guard AgentResume.quotedPath(path) != nil else {
            return "the config directory must not contain quotes, backslashes, ! or control characters"
        }
        return nil
    }

    /// Absolute, without `~`, `.`/`..` or a trailing slash.
    public static func expandedPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        var expanded = path
        if path == "~" { expanded = home } else if path.hasPrefix("~/") { expanded = home + path.dropFirst(1) }
        return (expanded as NSString).standardizingPath
    }

    /// The account whose directory is `configDir` (`CLAUDE_CONFIG_DIR` as Claude Code saw it; nil or empty =
    /// the default `~/.claude`). Paths are compared expanded, and also with symlinks resolved.
    public static func account(forConfigDir configDir: String?, in accounts: [ClaudeAccount],
                               home: String = NSHomeDirectory()) -> ClaudeAccount? {
        let raw = (configDir?.isEmpty ?? true) ? defaultConfigDir : configDir!
        let wanted = expandedPath(raw, home: home)
        if let exact = accounts.first(where: { expandedPath($0.configDir, home: home) == wanted }) { return exact }
        let resolved = (wanted as NSString).resolvingSymlinksInPath
        return accounts.first { (expandedPath($0.configDir, home: home) as NSString).resolvingSymlinksInPath == resolved }
    }

    /// The account to continue with after `current` hit its limit: the next one in the user's order (wrapping
    /// around) without an active limit, never `current` itself. nil when every other account is limited.
    public static func next(after current: String?, in accounts: [ClaudeAccount], now: Date = Date()) -> ClaudeAccount? {
        let start = current.flatMap { name in accounts.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
        let ordered = start.map { Array(accounts[($0 + 1)...] + accounts[..<$0]) } ?? accounts
        return ordered.first { !$0.isLimited(at: now) }
    }

    /// `--account auto`: the first account in order without an active limit.
    public static func firstAvailable(in accounts: [ClaudeAccount], now: Date = Date()) -> ClaudeAccount? {
        accounts.first { !$0.isLimited(at: now) }
    }

    /// The limit to keep when a new one is seen: a later reset wins; an estimate never replaces a known time
    /// that is still ahead.
    public static func merge(_ old: ClaudeAccountLimit?, _ new: ClaudeAccountLimit, now: Date = Date()) -> ClaudeAccountLimit {
        guard let old, old.isActive(at: now) else { return new }
        if new.estimated && !old.estimated { return old }
        if old.estimated && !new.estimated { return new }
        return new.resetsAt >= old.resetsAt ? new : old
    }
}

/// `claude-accounts.json` in the support directory (`CMDS_SUPPORT_DIR` for an isolated instance, so a test instance
/// never sees or changes the accounts of the app in use). Names, paths, limits and the switch setting only.
public enum ClaudeAccountStore {
    public static let fileName = "claude-accounts.json"

    public static func url(supportDirectory: URL = CmdsEnv.supportDirectoryURL()) -> URL {
        supportDirectory.appendingPathComponent(fileName)
    }

    /// Empty settings when the file is missing or unreadable.
    public static func load(from url: URL) -> ClaudeAccountSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(ClaudeAccountSettings.self, from: data) else { return ClaudeAccountSettings() }
        return settings
    }

    public static func save(_ settings: ClaudeAccountSettings, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(settings).write(to: url, options: [.atomic])
    }
}

/// One account in `account.list` (`cmds accounts`).
public struct ClaudeAccountStatus: Codable, Equatable, Sendable {
    public var name: String
    public var configDir: String
    /// The config directory exists (the user has created / signed in to it).
    public var exists: Bool
    /// The active limit; nil when the account can be used.
    public var limit: ClaudeAccountLimit?
    /// How `<configDir>/projects` relates to the shared sessions (`ClaudeSessionSharing`).
    public var sessions: ClaudeProjectsLink
    /// Terminal panes using this account now.
    public var panes: [String]

    public init(name: String, configDir: String, exists: Bool, limit: ClaudeAccountLimit?, sessions: ClaudeProjectsLink,
                panes: [String]) {
        self.name = name
        self.configDir = configDir
        self.exists = exists
        self.limit = limit
        self.sessions = sessions
        self.panes = panes
    }
}

/// Result of `account.list`.
public struct ClaudeAccountList: Codable, Equatable, Sendable {
    public var accounts: [ClaudeAccountStatus]
    public var autoSwitch: Bool

    public init(accounts: [ClaudeAccountStatus], autoSwitch: Bool) {
        self.accounts = accounts
        self.autoSwitch = autoSwitch
    }
}
