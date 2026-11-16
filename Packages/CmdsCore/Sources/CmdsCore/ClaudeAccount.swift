import Foundation

// Several Claude Code accounts of the user (docs/guide/ai-agents.md "Several Claude accounts").
// An account is a name and a Claude Code config directory (`CLAUDE_CONFIG_DIR`) the user signed in to once with
// `claude` → `/login`. cmds keeps only the name, the path and the last limit it saw; it never copies or stores what
// Claude Code keeps in that directory (credentials, settings, transcripts). The one thing it reads there is which
// sign-in the directory has (`ClaudeAccounts.signIn`: the account id in `.claude.json`, compared and never kept or
// shown), since two directories signed in to the same Claude account share one limit.

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

    /// Account names are unique ignoring case (`ClaudeAccountSettings`), so they are matched that way.
    public func hasName(_ other: String) -> Bool { name.caseInsensitiveCompare(other) == .orderedSame }
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
    /// The line that showed it (trimmed, at most `maxMessageLength` characters), for the user.
    public var message: String?

    public static let maxMessageLength = 200

    public init(kind: ClaudeLimitKind, resetsAt: Date, estimated: Bool = false, detectedAt: Date = Date(), message: String? = nil) {
        self.kind = kind
        self.resetsAt = resetsAt
        self.estimated = estimated
        self.detectedAt = detectedAt
        self.message = message.map(Self.shortened)
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
        message = c.lenientString(.message).map(Self.shortened)
    }

    private static func shortened(_ message: String) -> String { String(message.prefix(maxMessageLength)) }

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
        accounts.first { $0.hasName(name) }
    }
}

private struct Lossy<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// Rules for accounts: names, paths, matching a config dir to an account and choosing the next one.
public enum ClaudeAccounts {
    /// The environment variable that selects Claude Code's config directory.
    public static let configDirVariable = "CLAUDE_CONFIG_DIR"
    /// Claude Code's default config directory when `CLAUDE_CONFIG_DIR` is not set.
    public static let defaultConfigDir = "~/.claude"
    /// `--account auto` (`cmds new`, `cmds split`): the first account without an active limit.
    public static let automatic = "auto"
    public static let maxAccounts = 20
    public static let maxNameLength = 32

    /// Names are shown in the sidebar and typed on the command line: letters, digits, `-`, `_`, `.`, `@`, 1–32
    /// characters, starting with a letter or digit, not `auto`. nil when fine.
    public static func nameProblem(_ name: String) -> String? {
        guard (1...maxNameLength).contains(name.count) else { return "the name must be 1 to \(maxNameLength) characters" }
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

    /// `account.move` (`cmds accounts move`): the 0-based `index` must be a position in the list of `count` accounts;
    /// one beyond the end is refused, not clamped (#44). The message counts from 1, as the CLI does. nil when fine.
    public static func positionProblem(_ index: Int, count: Int) -> String? {
        guard !(0..<count).contains(index) else { return nil }
        return count == 1 ? "the position must be 1" : "the position must be 1 to \(count)"
    }

    /// Absolute, without `~`, `.`/`..` or a trailing slash.
    public static func expandedPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        var expanded = path
        if path == "~" { expanded = home } else if path.hasPrefix("~/") { expanded = home + path.dropFirst(1) }
        return (expanded as NSString).standardizingPath
    }

    /// `path` is the default config directory (`~/.claude`): an account on it is plain `claude`, run without
    /// `CLAUDE_CONFIG_DIR` (`AgentResume.command`, a pane opened with the account).
    public static func isDefaultConfigDir(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        expandedPath(path, home: home) == expandedPath(defaultConfigDir, home: home)
    }

    /// A name for an account on `configDir` (cmds offering to add a config folder it found in use, #360): the folder's
    /// name without the leading `.` and a `claude-` prefix (`~/.claude` → `claude`, `~/.claude-work` → `work`), only
    /// the characters names may have, made unique among `taken` with `-2`, `-3`…
    public static func suggestedName(forConfigDir configDir: String, taken: [String], home: String = NSHomeDirectory()) -> String {
        var base = (expandedPath(configDir, home: home) as NSString).lastPathComponent
        while base.hasPrefix(".") { base.removeFirst() }
        if base.lowercased().hasPrefix("claude-"), base.count > "claude-".count { base = String(base.dropFirst("claude-".count)) }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.@")
        base = String(String.UnicodeScalarView(base.unicodeScalars.filter(allowed.contains)))
        while let first = base.unicodeScalars.first, !CharacterSet.alphanumerics.contains(first) { base.removeFirst() }
        base = String(base.prefix(maxNameLength - 3))
        if base.isEmpty || nameProblem(base) != nil { base = "claude" }
        let lowered = Set(taken.map { $0.lowercased() })
        var name = base
        var counter = 2
        while lowered.contains(name.lowercased()) {
            name = "\(base)-\(counter)"
            counter += 1
        }
        return name
    }

    /// The account's config directory exists as a directory (the user has created / signed in to it).
    public static func configDirExists(_ account: ClaudeAccount, fileManager: FileManager = .default,
                                       home: String = NSHomeDirectory()) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: expandedPath(account.configDir, home: home), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// The account whose directory is `configDir` (`CLAUDE_CONFIG_DIR` as Claude Code saw it; nil or empty =
    /// the default `~/.claude`). Paths are compared expanded, and also with symlinks resolved.
    public static func account(forConfigDir configDir: String?, in accounts: [ClaudeAccount],
                               home: String = NSHomeDirectory()) -> ClaudeAccount? {
        let raw = configDir.flatMap { $0.isEmpty ? nil : $0 } ?? defaultConfigDir
        let wanted = expandedPath(raw, home: home)
        if let exact = accounts.first(where: { expandedPath($0.configDir, home: home) == wanted }) { return exact }
        let resolved = (wanted as NSString).resolvingSymlinksInPath
        return accounts.first { (expandedPath($0.configDir, home: home) as NSString).resolvingSymlinksInPath == resolved }
    }

    /// The Claude sign-in of the account's config directory: the account id Claude Code records in
    /// `<configDir>/.claude.json` (`oauthAccount.accountUuid`); for the default directory, `~/.claude.json` first,
    /// the file of a plain `claude`, which is how cmds runs that account (#360). nil when not signed in (or not
    /// readable). Only for comparing accounts: never stored, logged or sent anywhere.
    public static func signIn(of account: ClaudeAccount, home: String = NSHomeDirectory()) -> String? {
        let dir = expandedPath(account.configDir, home: home)
        var files = [dir + "/.claude.json"]
        if isDefaultConfigDir(dir, home: home) { files.insert(home + "/.claude.json", at: 0) }
        for file in files {
            guard let data = FileManager.default.contents(atPath: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let id = (object["oauthAccount"] as? [String: Any])?["accountUuid"] as? String, !id.isEmpty { return id }
        }
        return nil
    }

    /// The other accounts signed in to the same Claude account as `account` (one limit for all of them).
    public static func sameSignIn(as account: ClaudeAccount, in accounts: [ClaudeAccount],
                                  signIn: (ClaudeAccount) -> String? = { ClaudeAccounts.signIn(of: $0) }) -> [ClaudeAccount] {
        guard let own = signIn(account) else { return [] }
        return accounts.filter { !$0.hasName(account.name) && signIn($0) == own }
    }

    /// The account to continue with after `current` hit its limit: the next one in the user's order (wrapping
    /// around) without an active limit whose config directory exists (`usable`), never `current` itself. nil when
    /// every other account is limited or missing.
    public static func next(after current: String?, in accounts: [ClaudeAccount], now: Date = Date(),
                            usable: (ClaudeAccount) -> Bool = { configDirExists($0) }) -> ClaudeAccount? {
        let start = current.flatMap { name in accounts.firstIndex { $0.hasName(name) } }
        let ordered = start.map { Array(accounts[($0 + 1)...] + accounts[..<$0]) } ?? accounts
        return ordered.first { !$0.isLimited(at: now) && usable($0) }
    }

    /// `--account auto`: the first account in order without an active limit whose config directory exists (`usable`).
    public static func firstAvailable(in accounts: [ClaudeAccount], now: Date = Date(),
                                      usable: (ClaudeAccount) -> Bool = { configDirExists($0) }) -> ClaudeAccount? {
        accounts.first { !$0.isLimited(at: now) && usable($0) }
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

    /// What `load` found.
    public struct Loaded {
        /// Empty when the file is missing or could not be read.
        public var settings: ClaudeAccountSettings
        /// Why the file could not be read or decoded; nil when it was missing or fine.
        public var error: Error?
        /// Where an undecodable file was moved (kept, `StoredFile.moveAside`).
        public var movedAside: URL?
        /// The file could not be read and is still in place: saving would overwrite the user's accounts.
        public var saveBlocked: Bool { error != nil && movedAside == nil }
    }

    /// Through `StoredFile` (#46): a damaged file is moved aside to `claude-accounts.json.corrupt-<date>` (kept) and
    /// the settings start empty; a file that cannot be read stays in place and must not be saved over (`saveBlocked`).
    public static func load(from url: URL, now: Date = Date()) -> Loaded {
        switch StoredFile.load(ClaudeAccountSettings.self, from: url, now: now) {
        case .missing:
            return Loaded(settings: ClaudeAccountSettings())
        case .loaded(let settings):
            return Loaded(settings: settings)
        case .unreadable(let error, .success(let moved)):
            return Loaded(settings: ClaudeAccountSettings(), error: error, movedAside: moved)
        case .unreadable(let error, .failure):
            return Loaded(settings: ClaudeAccountSettings(), error: error)
        }
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
    /// Another account (the first in the list) whose config directory is signed in to the same Claude account: they
    /// share one limit, so a session never switches between them. nil when there is none.
    public var sameSignInAs: String?
    /// The account's `settings.json` lacks cmds's status line or hooks (`ClaudeAccountSetup`): its panes show no
    /// account button and cannot be switched. nil when the config directory does not exist.
    public var needsSetup: Bool?

    public init(name: String, configDir: String, exists: Bool, limit: ClaudeAccountLimit?, sessions: ClaudeProjectsLink,
                panes: [String], sameSignInAs: String? = nil, needsSetup: Bool? = nil) {
        self.sameSignInAs = sameSignInAs
        self.needsSetup = needsSetup
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
    /// Claude in Chrome's host scripts that a browser's manifest names but that are missing (`ClaudeChromeHost`):
    /// the extension cannot connect under any account. nil when there are none.
    public var chromeHostMissing: [String]?

    public init(accounts: [ClaudeAccountStatus], autoSwitch: Bool, chromeHostMissing: [String]? = nil) {
        self.accounts = accounts
        self.autoSwitch = autoSwitch
        self.chromeHostMissing = chromeHostMissing
    }
}
