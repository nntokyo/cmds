import Foundation

/// Reads the usage figures out of Codex CLI session files (`$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`).
///
/// PRIVACY: these files hold the user's conversations. Only lines mentioning `token_count` (usage events) or
/// `turn_context` (model and reasoning effort) are decoded, into types that have just those fields; everything
/// else is skipped unparsed and nothing read here is logged or stored beyond the resulting figures.
public enum CodexRollout {
    /// Tokens Codex assumes for its own prompt when computing "context left" (codex-rs `BASELINE_TOKENS`).
    public static let baselineTokens = 12_000

    /// Figures from the newest relevant lines of a rollout file.
    public struct Snapshot: Equatable, Sendable {
        public struct Tokens: Equatable, Sendable {
            public var input = 0
            public var cachedInput = 0
            public var output = 0
            public var reasoning = 0
            public var total = 0
            public init() {}
        }

        /// Session totals and the last turn (what is in the context window).
        public var total: Tokens?
        public var last: Tokens?
        public var contextWindow: Int?
        public var usageDate: Date?
        public var limits: [UsageLimit] = []
        public var limitsDate: Date?
        public var plan: String?
        public var model: String?
        public var effort: String?

        public init() {}

        public var hasUsage: Bool { last != nil || total != nil }

        /// Overlays `newer` (read from later lines) on these figures.
        public mutating func merge(_ newer: Snapshot) {
            if newer.hasUsage {
                total = newer.total ?? total
                last = newer.last ?? last
                contextWindow = newer.contextWindow ?? contextWindow
                usageDate = newer.usageDate ?? usageDate
            }
            if !newer.limits.isEmpty {
                limits = newer.limits
                limitsDate = newer.limitsDate
            }
            plan = newer.plan ?? plan
            model = newer.model ?? model
            effort = newer.effort ?? effort
        }

        /// Pane usage; nil until the session reported tokens.
        public func usage(sessionID: String?, fallbackDate: Date) -> AgentUsage? {
            guard hasUsage else { return nil }
            var usage = AgentUsage(agent: .codex, model: model, effort: effort, sessionID: sessionID,
                                   limits: limits, plan: plan, updatedAt: usageDate ?? fallbackDate)
            if let last {
                let inContext = max(0, last.total &- last.reasoning)
                usage.contextTokens = inContext
                if let window = contextWindow, window > 0 {
                    usage.contextWindow = window
                    usage.contextUsedPercent = CodexRollout.contextUsedPercent(tokens: inContext, window: window)
                }
            }
            if let total {
                usage.inputTokens = total.input
                usage.cachedInputTokens = total.cachedInput
                usage.outputTokens = total.output
                usage.reasoningTokens = total.reasoning
            }
            return usage
        }

        /// Account limits from the newest usage event that had them.
        public func accountLimits(fallbackDate: Date) -> AgentLimits? {
            guard !limits.isEmpty else { return nil }
            return AgentLimits(agent: .codex, limits: limits, plan: plan, updatedAt: limitsDate ?? fallbackDate)
        }
    }

    /// Codex's "context left" turned around: share of the window above the baseline that the last turn used.
    public static func contextUsedPercent(tokens: Int, window: Int) -> Double {
        guard window > baselineTokens else { return 100 }
        let effective = Double(window - baselineTokens)
        let used = Double(max(0, tokens - baselineTokens))
        let remaining = max(0, effective - used)
        return 100 - min(100, max(0, (remaining / effective * 100).rounded()))
    }

    /// Parses JSONL `data` that starts at a line boundary. An unterminated last line is ignored; `consumed`
    /// is the number of bytes up to and including the last newline (where an incremental read continues).
    public static func parse(_ data: Data) -> (snapshot: Snapshot, consumed: Int) {
        var snapshot = Snapshot()
        let decoder = JSONDecoder()
        var consumed = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var start = 0
            while start < raw.count, let newline = memchr(base + start, 0x0A, raw.count - start) {
                let end = base.distance(to: UnsafeRawPointer(newline))
                defer { start = end + 1 }
                consumed = end + 1
                let line = UnsafeRawBufferPointer(start: base + start, count: end - start)
                guard line.count > 2, contains(line, tokenCountMarker) || contains(line, turnContextMarker),
                      let entry = try? decoder.decode(Line.self, from: Data(line)) else { continue }
                apply(entry, to: &snapshot)
            }
        }
        return (snapshot, consumed)
    }

    /// Session id and working directory from the first line (`session_meta`).
    public struct SessionMeta: Equatable, Sendable {
        public var id: String?
        public var cwd: String?
        public var timestamp: Date?
    }

    public static func sessionMeta(firstLine: Data) -> SessionMeta? {
        guard let entry = try? JSONDecoder().decode(MetaLine.self, from: firstLine), entry.type == "session_meta",
              let payload = entry.payload else { return nil }
        return SessionMeta(id: payload.id, cwd: payload.cwd,
                           timestamp: (payload.timestamp ?? entry.timestamp).flatMap(FlexibleDate.date(from:)))
    }

    /// `true` for `…/rollout-<date>-<id>.jsonl`.
    public static func isRolloutPath(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
    }

    /// The session id at the end of a rollout file name (a UUID), if any.
    public static func sessionID(fromPath path: String) -> String? {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard name.count >= 36 else { return nil }
        let candidate = String(name.suffix(36))
        return UUID(uuidString: candidate) != nil ? candidate.lowercased() : nil
    }

    // MARK: - Decoding (only the fields we use)

    private static let tokenCountMarker = Array(#""token_count""#.utf8)
    private static let turnContextMarker = Array(#""turn_context""#.utf8)

    private struct Line: Decodable {
        var timestamp: String?
        var type: String?
        var payload: Payload?
    }

    private struct Payload: Decodable {
        var type: Lenient<String>?
        var info: Lenient<Info>?
        var rate_limits: Lenient<RateLimits>?
        var model: Lenient<String>?
        var effort: Lenient<String>?
    }

    /// A field of another shape decodes as nil instead of failing the line.
    private struct Lenient<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    private struct Info: Decodable {
        var total_token_usage: Usage?
        var last_token_usage: Usage?
        var model_context_window: Int?
    }

    private struct Usage: Decodable {
        var input_tokens: Int?
        var cached_input_tokens: Int?
        var output_tokens: Int?
        var reasoning_output_tokens: Int?
        var total_tokens: Int?

        var tokens: Snapshot.Tokens {
            var tokens = Snapshot.Tokens()
            tokens.input = input_tokens ?? 0
            tokens.cachedInput = cached_input_tokens ?? 0
            tokens.output = output_tokens ?? 0
            tokens.reasoning = reasoning_output_tokens ?? 0
            tokens.total = total_tokens ?? (tokens.input &+ tokens.output)
            return tokens
        }
    }

    private struct RateLimits: Decodable {
        var primary: Window?
        var secondary: Window?
        var plan_type: String?
    }

    private struct Window: Decodable {
        var used_percent: Double?
        var window_minutes: Int?
        var resets_at: Double?
        /// Older Codex versions.
        var resets_in_seconds: Double?
    }

    private struct MetaLine: Decodable {
        var timestamp: String?
        var type: String?
        var payload: MetaPayload?
    }

    private struct MetaPayload: Decodable {
        var id: String?
        var cwd: String?
        var timestamp: String?
    }

    private static func apply(_ entry: Line, to snapshot: inout Snapshot) {
        let date = entry.timestamp.flatMap(FlexibleDate.date(from:))
        switch entry.type {
        case "event_msg":
            guard let payload = entry.payload, payload.type?.value == "token_count" else { return }
            if let info = payload.info?.value, info.total_token_usage != nil || info.last_token_usage != nil {
                snapshot.total = info.total_token_usage?.tokens ?? snapshot.total
                snapshot.last = info.last_token_usage?.tokens ?? snapshot.last
                snapshot.contextWindow = info.model_context_window ?? snapshot.contextWindow
                snapshot.usageDate = date ?? snapshot.usageDate
            }
            // Some events carry another limit family with empty windows; keep the last real ones.
            if let rates = payload.rate_limits?.value {
                let windows = [(rates.primary, "primary"), (rates.secondary, "secondary")].compactMap { window, name in
                    window.flatMap { limit(from: $0, fallbackID: name, eventDate: date) }
                }
                if !windows.isEmpty {
                    snapshot.limits = windows
                    snapshot.limitsDate = date
                    snapshot.plan = rates.plan_type ?? snapshot.plan
                }
            }
        case "turn_context":
            if let model = entry.payload?.model?.value, !model.isEmpty { snapshot.model = model }
            if let effort = entry.payload?.effort?.value, !effort.isEmpty { snapshot.effort = effort }
        default:
            return
        }
    }

    private static func limit(from window: Window, fallbackID: String, eventDate: Date?) -> UsageLimit? {
        guard let used = window.used_percent, used.isFinite else { return nil }
        let id: String
        switch window.window_minutes {
        case 300?: id = UsageLimit.fiveHour
        case 10080?: id = UsageLimit.sevenDay
        default: id = fallbackID
        }
        var resetsAt = window.resets_at.flatMap(FlexibleDate.date(epoch:))
        if resetsAt == nil, let seconds = window.resets_in_seconds, let eventDate {
            resetsAt = eventDate.addingTimeInterval(seconds)
        }
        return UsageLimit(id: id, usedPercent: used, resetsAt: resetsAt, windowMinutes: window.window_minutes)
    }

    private static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard haystack.count >= needle.count, let base = haystack.baseAddress else { return false }
        return needle.withUnsafeBytes { n in memmem(base, haystack.count, n.baseAddress, n.count) != nil }
    }
}

/// Decides which Codex session file belongs to which pane.
///
/// A Codex process that writes its own session holds the rollout file open, which settles it. Codex TUIs that run
/// their sessions in the shared app-server daemon (`codex app-server`, the default since Codex 0.16x) hold no
/// file: the daemon does. Such a file is matched by the session's working directory (`session_meta.cwd`) and
/// time: it goes to the pane whose Codex started most recently before the session was created (a new session or
/// `/new`), else — for a resumed session — to the one that started most recently before its last write. Two Codex
/// panes in the same directory can still be confused when the older one starts a new session.
public enum CodexSessionMatcher {
    public struct Pane: Equatable, Sendable {
        public var paneID: String
        /// Start of the pane's Codex process.
        public var started: Date
        public var cwd: String?
        /// Rollout files the pane's Codex processes hold open.
        public var openFiles: [String]

        public init(paneID: String, started: Date, cwd: String?, openFiles: [String] = []) {
            self.paneID = paneID
            self.started = started
            self.cwd = cwd
            self.openFiles = openFiles
        }
    }

    public struct File: Equatable, Sendable {
        public var path: String
        /// From `session_meta`; nil when unknown (matches any directory).
        public var cwd: String?
        public var created: Date?
        public var modified: Date
        /// The file has a usage event (files without one are only taken when a pane holds them).
        public var hasUsage: Bool

        public init(path: String, cwd: String?, created: Date?, modified: Date, hasUsage: Bool) {
            self.path = path
            self.cwd = cwd
            self.created = created
            self.modified = modified
            self.hasUsage = hasUsage
        }
    }

    /// Slack between a process start and the session it creates (clock granularity).
    static let startSlack: TimeInterval = 2

    /// - Parameters:
    ///   - panes: panes running a Codex session process.
    ///   - files: every known rollout file (held by a pane or by a daemon).
    /// - Returns: rollout path per pane ID.
    public static func match(panes: [Pane], files: [File]) -> [String: String] {
        let byPath = Dictionary(files.map { ($0.path, $0) }) { first, _ in first }
        var result: [String: String] = [:]
        var claimed = Set<String>()
        // Files a pane holds itself: the newest one with usage, else the newest.
        for pane in panes {
            let held = pane.openFiles.compactMap { byPath[$0] }
            claimed.formUnion(held.map(\.path))
            let pick = held.filter(\.hasUsage).max { $0.modified < $1.modified } ?? held.max { $0.modified < $1.modified }
            if let pick { result[pane.paneID] = pick.path }
        }
        let open = panes.filter { result[$0.paneID] == nil }
        guard !open.isEmpty else { return result }
        var owned: [String: [File]] = [:]
        for file in files where file.hasUsage && !claimed.contains(file.path) {
            let owners = open.filter { sameDirectory($0.cwd, file.cwd) }
            let created = file.created ?? file.modified
            let owner = owners.filter { $0.started <= created.addingTimeInterval(startSlack) }.max { $0.started < $1.started }
                ?? owners.filter { $0.started <= file.modified }.max { $0.started < $1.started }
            if let owner { owned[owner.paneID, default: []].append(file) }
        }
        for (paneID, candidates) in owned {
            if let newest = candidates.max(by: { $0.modified < $1.modified }) { result[paneID] = newest.path }
        }
        return result
    }

    /// Same path, ignoring `/private` (`/tmp` vs `/private/tmp`); nil matches anything.
    public static func sameDirectory(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return true }
        return normalize(a) == normalize(b)
    }

    private static func normalize(_ path: String) -> String {
        var path = (path as NSString).standardizingPath
        if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
        return path
    }
}

/// Recognises agent processes from their executable path and arguments (`KERN_PROCARGS2`).
public enum AgentProcessClassifier {
    public enum CodexRole: Equatable, Sendable {
        /// An interactive or `exec`/`review` session.
        case session
        /// A shared server that runs sessions for clients (`codex app-server` daemon, MCP server).
        case service
        /// Any other subcommand (login, features…).
        case utility
    }

    /// Claude Code (native build in `…/claude/versions/<v>`, `claude` launcher or the npm package) or Codex.
    public static func agent(executablePath: String, arguments: [String]) -> AgentKind? {
        let executable = (executablePath as NSString).lastPathComponent
        let first = arguments.first.map { ($0 as NSString).lastPathComponent } ?? ""
        // Script run by an interpreter (npm installs: `node …/bin/codex`).
        let script = arguments.dropFirst().first ?? ""
        let scriptName = (script as NSString).lastPathComponent
        if executable == "codex" || first == "codex" || scriptName == "codex" || scriptName == "codex.js"
            || script.contains("@openai/codex/") {
            return .codex
        }
        if executable == "claude" || first == "claude" || executablePath.contains("/claude/versions/")
            || scriptName == "claude" || script.contains("@anthropic-ai/claude-code/") {
            return .claude
        }
        return nil
    }

    private static let serviceCommands: Set<String> = ["app-server", "exec-server", "mcp-server"]
    private static let utilityCommands: Set<String> = [
        "login", "logout", "mcp", "completion", "sandbox", "debug", "features", "doctor", "update", "app",
        "remote-control", "cloud", "apply", "a", "plugin", "agents", "archive", "unarchive", "delete",
        "migrate-rollouts", "queue", "help", "--version", "-V", "--help", "-h",
    ]

    public static func codexRole(arguments: [String]) -> CodexRole {
        var rest = Array(arguments.dropFirst())
        if let script = rest.first, script.hasSuffix(".js") || script.hasSuffix("/codex") { rest.removeFirst() } // node wrapper
        if rest.contains(where: serviceCommands.contains) { return .service }
        if let command = rest.first(where: { !$0.hasPrefix("-") || ["--version", "-V", "--help", "-h"].contains($0) }),
           utilityCommands.contains(command) {
            return .utility
        }
        return .session
    }

    /// Shells and wrappers between an agent and the hooks it runs.
    public static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh", "env", "timeout", "nice", "nohup"]
}

/// Parses a `KERN_PROCARGS2` buffer: argc, executable path, argv, environment.
public enum ProcessArguments {
    /// - Parameters:
    ///   - buffer: the sysctl result.
    ///   - maxArguments: argv entries to return (the rest is skipped).
    ///   - environmentNames: variables to pick from the environment.
    public static func parse(_ buffer: UnsafeRawBufferPointer, maxArguments: Int = 6,
                             environmentNames: [String] = []) -> (executable: String, arguments: [String], environment: [String: String])? {
        let size = buffer.count
        guard size > MemoryLayout<Int32>.size else { return nil }
        let bytes = buffer.bindMemory(to: UInt8.self)
        let argc = Int(buffer.loadUnaligned(as: Int32.self))
        var index = MemoryLayout<Int32>.size
        func string(from start: Int, to end: Int) -> String {
            String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
        }
        let executableStart = index
        while index < size, bytes[index] != 0 { index += 1 }
        let executable = string(from: executableStart, to: index)
        while index < size, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        var skipped = 0
        while index < size, skipped < argc {
            let start = index
            while index < size, bytes[index] != 0 { index += 1 }
            if arguments.count < maxArguments { arguments.append(string(from: start, to: index)) }
            index += 1
            skipped += 1
        }
        var environment: [String: String] = [:]
        guard !environmentNames.isEmpty else { return (executable, arguments, environment) }
        let prefixes = environmentNames.map { (name: $0, bytes: Array(($0 + "=").utf8)) }
        while index < size, bytes[index] != 0, environment.count < prefixes.count {
            let start = index
            while index < size, bytes[index] != 0 { index += 1 }
            for prefix in prefixes where environment[prefix.name] == nil && index - start > prefix.bytes.count
                && prefix.bytes.indices.allSatisfy({ bytes[start + $0] == prefix.bytes[$0] }) {
                environment[prefix.name] = string(from: start + prefix.bytes.count, to: index)
            }
            index += 1
        }
        return (executable, arguments, environment)
    }
}
