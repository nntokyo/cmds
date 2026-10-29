import Foundation

// Usage and limits of the AI coding agents running in cmds panes (Claude Code, Codex).
// Sent in `PaneInfo.agent`, the socket methods `agent.list` / `system.stats` and the sync `state`.
// Dates are encoded as Unix epoch seconds (numbers); decoding also accepts milliseconds and ISO 8601 strings.

/// Which coding agent a record describes. Unknown names decode as `.other`.
public enum AgentKind: String, Codable, Sendable, CaseIterable, Comparable {
    case claude
    case codex
    case other

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentKind(rawValue: raw.lowercased()) ?? .other
    }

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .other: return "Agent"
        }
    }

    private var order: Int { AgentKind.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: AgentKind, rhs: AgentKind) -> Bool { lhs.order < rhs.order }
}

/// One account-level usage window or limit (Claude: 5-hour, 7-day, spend limit; Codex: primary/secondary windows).
public struct UsageLimit: Codable, Equatable, Sendable, Identifiable {
    public static let fiveHour = "five_hour"
    public static let sevenDay = "seven_day"
    public static let spend = "spend"

    /// `five_hour`, `seven_day`, `spend`, or another window name as reported.
    public var id: String
    /// Share of the limit used, 0–100 (a spend limit can go above 100).
    public var usedPercent: Double
    /// When the window resets; nil if unknown.
    public var resetsAt: Date?
    /// Window length in minutes (300 for five_hour, 10080 for seven_day) when known.
    public var windowMinutes: Int?
    /// Spend limits: money used and the limit, USD.
    public var usedUSD: Double?
    public var limitUSD: Double?
    /// Spend limits: `daily`, `weekly` or `monthly` as reported.
    public var period: String?

    public init(id: String, usedPercent: Double, resetsAt: Date? = nil, windowMinutes: Int? = nil,
                usedUSD: Double? = nil, limitUSD: Double? = nil, period: String? = nil) {
        self.id = id
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes ?? Self.knownWindowMinutes(id)
        self.usedUSD = usedUSD
        self.limitUSD = limitUSD
        self.period = period
    }

    static func knownWindowMinutes(_ id: String) -> Int? {
        switch id {
        case fiveHour: return 300
        case sevenDay: return 10080
        default: return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, usedPercent, resetsAt, windowMinutes, usedUSD, limitUSD, period
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        guard let used = c.lenientDouble(.usedPercent) else {
            throw DecodingError.keyNotFound(CodingKeys.usedPercent, .init(codingPath: c.codingPath, debugDescription: "usedPercent"))
        }
        usedPercent = used
        resetsAt = c.lenientDate(.resetsAt)
        windowMinutes = c.lenientInt(.windowMinutes) ?? Self.knownWindowMinutes(id)
        usedUSD = c.lenientDouble(.usedUSD)
        limitUSD = c.lenientDouble(.limitUSD)
        period = c.lenientString(.period)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(usedPercent, forKey: .usedPercent)
        try c.encodeIfPresent(resetsAt?.timeIntervalSince1970, forKey: .resetsAt)
        try c.encodeIfPresent(windowMinutes, forKey: .windowMinutes)
        try c.encodeIfPresent(usedUSD, forKey: .usedUSD)
        try c.encodeIfPresent(limitUSD, forKey: .limitUSD)
        try c.encodeIfPresent(period, forKey: .period)
    }

    /// The window has reset: its usage is no longer known.
    public func hasReset(at now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    /// Share of the window that has elapsed, 0–100 (nil without reset time or length).
    public func elapsedPercent(at now: Date) -> Double? {
        guard let resetsAt, let minutes = windowMinutes, minutes > 0 else { return nil }
        let window = Double(minutes) * 60
        let left = min(max(resetsAt.timeIntervalSince(now), 0), window)
        return (window - left) / window * 100
    }
}

/// Session usage of the agent running in one pane.
public struct AgentUsage: Codable, Equatable, Sendable {
    public var agent: AgentKind
    /// Model display name (`Opus 4.5`, `gpt-5-codex`).
    public var model: String?
    /// Reasoning effort (`high`, `low`…).
    public var effort: String?
    public var sessionID: String?
    /// Context window in use, 0–100.
    public var contextUsedPercent: Double?
    public var contextTokens: Int?
    public var contextWindow: Int?
    /// Claude Code: the conversation exceeds 200k tokens (long-context pricing).
    public var contextOver200k: Bool?
    /// Session cost so far, USD (Claude Code).
    public var costUSD: Double?
    /// Wall time of the session and time spent waiting for the API, ms.
    public var sessionDurationMs: Int?
    public var apiDurationMs: Int?
    public var linesAdded: Int?
    public var linesRemoved: Int?
    /// Prompt cache hit ratio, 0–1, and whether the cache is warm.
    public var cacheHitRatio: Double?
    public var cacheWarm: Bool?
    /// Session token totals (Codex).
    public var inputTokens: Int?
    public var cachedInputTokens: Int?
    public var outputTokens: Int?
    public var reasoningTokens: Int?
    /// Account limits as seen by this session (the latest per agent kind is in `AgentLimits`).
    public var limits: [UsageLimit]
    /// Subscription plan when reported (Codex `plus`, `pro`…).
    public var plan: String?
    /// When the Mac received (Claude) or the agent wrote (Codex) this data.
    public var updatedAt: Date
    /// Set by the Mac when no update arrived for a few minutes (the agent is idle or gone). Omitted when false.
    public var stale: Bool?

    public init(agent: AgentKind, model: String? = nil, effort: String? = nil, sessionID: String? = nil,
                contextUsedPercent: Double? = nil, contextTokens: Int? = nil, contextWindow: Int? = nil,
                contextOver200k: Bool? = nil, costUSD: Double? = nil, sessionDurationMs: Int? = nil,
                apiDurationMs: Int? = nil, linesAdded: Int? = nil, linesRemoved: Int? = nil,
                cacheHitRatio: Double? = nil, cacheWarm: Bool? = nil, inputTokens: Int? = nil,
                cachedInputTokens: Int? = nil, outputTokens: Int? = nil, reasoningTokens: Int? = nil,
                limits: [UsageLimit] = [], plan: String? = nil, updatedAt: Date = Date(), stale: Bool? = nil) {
        self.agent = agent
        self.model = model
        self.effort = effort
        self.sessionID = sessionID
        self.contextUsedPercent = contextUsedPercent
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.contextOver200k = contextOver200k
        self.costUSD = costUSD
        self.sessionDurationMs = sessionDurationMs
        self.apiDurationMs = apiDurationMs
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.cacheHitRatio = cacheHitRatio
        self.cacheWarm = cacheWarm
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.limits = limits
        self.plan = plan
        self.updatedAt = updatedAt
        self.stale = stale
    }

    public var isStale: Bool { stale == true }

    /// Same data apart from the bookkeeping fields (`updatedAt`, `stale`).
    public func sameFigures(as other: AgentUsage) -> Bool {
        var a = self, b = other
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        a.stale = nil
        b.stale = nil
        return a == b
    }

    private enum CodingKeys: String, CodingKey {
        case agent, model, effort, sessionID, contextUsedPercent, contextTokens, contextWindow, contextOver200k
        case costUSD, sessionDurationMs, apiDurationMs, linesAdded, linesRemoved, cacheHitRatio, cacheWarm
        case inputTokens, cachedInputTokens, outputTokens, reasoningTokens, limits, plan, updatedAt, stale
    }

    /// Lenient: a field of the wrong type is dropped instead of failing the whole record; a missing
    /// `updatedAt` means now.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent = (try? c.decode(AgentKind.self, forKey: .agent)) ?? .other
        model = c.lenientString(.model)
        effort = c.lenientString(.effort)
        sessionID = c.lenientString(.sessionID)
        contextUsedPercent = c.lenientDouble(.contextUsedPercent)
        contextTokens = c.lenientInt(.contextTokens)
        contextWindow = c.lenientInt(.contextWindow)
        contextOver200k = c.lenientBool(.contextOver200k)
        costUSD = c.lenientDouble(.costUSD)
        sessionDurationMs = c.lenientInt(.sessionDurationMs)
        apiDurationMs = c.lenientInt(.apiDurationMs)
        linesAdded = c.lenientInt(.linesAdded)
        linesRemoved = c.lenientInt(.linesRemoved)
        cacheHitRatio = c.lenientDouble(.cacheHitRatio)
        cacheWarm = c.lenientBool(.cacheWarm)
        inputTokens = c.lenientInt(.inputTokens)
        cachedInputTokens = c.lenientInt(.cachedInputTokens)
        outputTokens = c.lenientInt(.outputTokens)
        reasoningTokens = c.lenientInt(.reasoningTokens)
        limits = c.lenientLimits(.limits)
        plan = c.lenientString(.plan)
        updatedAt = c.lenientDate(.updatedAt) ?? Date()
        stale = c.lenientBool(.stale)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(agent, forKey: .agent)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(effort, forKey: .effort)
        try c.encodeIfPresent(sessionID, forKey: .sessionID)
        try c.encodeIfPresent(contextUsedPercent, forKey: .contextUsedPercent)
        try c.encodeIfPresent(contextTokens, forKey: .contextTokens)
        try c.encodeIfPresent(contextWindow, forKey: .contextWindow)
        try c.encodeIfPresent(contextOver200k, forKey: .contextOver200k)
        try c.encodeIfPresent(costUSD, forKey: .costUSD)
        try c.encodeIfPresent(sessionDurationMs, forKey: .sessionDurationMs)
        try c.encodeIfPresent(apiDurationMs, forKey: .apiDurationMs)
        try c.encodeIfPresent(linesAdded, forKey: .linesAdded)
        try c.encodeIfPresent(linesRemoved, forKey: .linesRemoved)
        try c.encodeIfPresent(cacheHitRatio, forKey: .cacheHitRatio)
        try c.encodeIfPresent(cacheWarm, forKey: .cacheWarm)
        try c.encodeIfPresent(inputTokens, forKey: .inputTokens)
        try c.encodeIfPresent(cachedInputTokens, forKey: .cachedInputTokens)
        try c.encodeIfPresent(outputTokens, forKey: .outputTokens)
        try c.encodeIfPresent(reasoningTokens, forKey: .reasoningTokens)
        try c.encode(limits, forKey: .limits)
        try c.encodeIfPresent(plan, forKey: .plan)
        try c.encode(updatedAt.timeIntervalSince1970, forKey: .updatedAt)
        if stale == true { try c.encode(true, forKey: .stale) }
    }
}

/// Latest account limits of one agent kind (whichever pane reported them last).
public struct AgentLimits: Codable, Equatable, Sendable, Identifiable {
    public var agent: AgentKind
    public var limits: [UsageLimit]
    public var plan: String?
    public var updatedAt: Date

    public var id: String { agent.rawValue }

    public init(agent: AgentKind, limits: [UsageLimit], plan: String? = nil, updatedAt: Date = Date()) {
        self.agent = agent
        self.limits = limits
        self.plan = plan
        self.updatedAt = updatedAt
    }

    /// Without the windows that have reset since (their usage is unknown); nil when none is left.
    public func active(at now: Date) -> AgentLimits? {
        var copy = self
        copy.limits = limits.filter { !$0.hasReset(at: now) }
        return copy.limits.isEmpty ? nil : copy
    }

    /// The 5-hour and 7-day windows first, then the rest in reported order.
    public var ordered: [UsageLimit] {
        let rank = [UsageLimit.fiveHour: 0, UsageLimit.sevenDay: 1, UsageLimit.spend: 3]
        return limits.enumerated().sorted { a, b in
            let ra = rank[a.element.id] ?? 2, rb = rank[b.element.id] ?? 2
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    private enum CodingKeys: String, CodingKey { case agent, limits, plan, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent = (try? c.decode(AgentKind.self, forKey: .agent)) ?? .other
        limits = c.lenientLimits(.limits)
        plan = c.lenientString(.plan)
        updatedAt = c.lenientDate(.updatedAt) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(agent, forKey: .agent)
        try c.encode(limits, forKey: .limits)
        try c.encodeIfPresent(plan, forKey: .plan)
        try c.encode(updatedAt.timeIntervalSince1970, forKey: .updatedAt)
    }
}

/// One entry of `agent.list`.
public struct AgentPaneUsage: Codable, Equatable, Sendable {
    public var workspace: String
    public var pane: String
    public var usage: AgentUsage

    public init(workspace: String, pane: String, usage: AgentUsage) {
        self.workspace = workspace
        self.pane = pane
        self.usage = usage
    }
}

/// Result of the socket method `agent.list`.
public struct AgentList: Codable, Equatable, Sendable {
    /// Panes running an agent, in sidebar order.
    public var panes: [AgentPaneUsage]
    /// Latest account limits per agent kind (windows that have reset are left out).
    public var limits: [AgentLimits]

    public init(panes: [AgentPaneUsage], limits: [AgentLimits]) {
        self.panes = panes
        self.limits = limits
    }
}

extension WorkspaceInfo {
    /// The agent shown for the workspace: the focused pane's, else the most recently updated one.
    public var primaryAgent: (pane: PaneInfo, usage: AgentUsage)? {
        AgentUsage.primary(panes.compactMap { pane in pane.agent.map { (pane, pane.focused, $0) } })
    }
}

extension AgentUsage {
    /// The focused candidate if it has an agent, else the most recently updated one.
    public static func primary<Item>(_ candidates: [(Item, Bool, AgentUsage)]) -> (Item, AgentUsage)? {
        if let focused = candidates.first(where: { $0.1 }) { return (focused.0, focused.2) }
        guard let latest = candidates.max(by: { $0.2.updatedAt < $1.2.updatedAt }) else { return nil }
        return (latest.0, latest.2)
    }
}

extension Array where Element == AgentLimits {
    public func limits(for agent: AgentKind) -> AgentLimits? { first { $0.agent == agent } }
}

// MARK: - Lenient decoding helpers

/// Epoch seconds (or milliseconds when > 1e11), a numeric string or an ISO 8601 date.
public enum FlexibleDate {
    public static func date(from value: JSONValue?) -> Date? {
        switch value {
        case .number(let number)?: return date(epoch: number)
        case .string(let string)?: return date(from: string)
        default: return nil
        }
    }

    public static func date(epoch number: Double) -> Date? {
        guard number.isFinite, number > 0 else { return nil }
        return Date(timeIntervalSince1970: number > 1e11 ? number / 1000 : number)
    }

    public static func date(from string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if let number = Double(trimmed) { return date(epoch: number) }
        if let date = try? Date(trimmed, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(trimmed, strategy: Date.ISO8601FormatStyle())
    }
}

extension KeyedDecodingContainer {
    func lenientString(_ key: Key) -> String? {
        guard let value = try? decodeIfPresent(JSONValue.self, forKey: key) else { return nil }
        switch value {
        case .string(let string): return string.isEmpty ? nil : string
        case .number(let number): return number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        default: return nil
        }
    }

    func lenientDouble(_ key: Key) -> Double? {
        guard let value = try? decodeIfPresent(JSONValue.self, forKey: key) else { return nil }
        switch value {
        case .number(let number): return number.isFinite ? number : nil
        case .string(let string): return Double(string.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        default: return nil
        }
    }

    func lenientInt(_ key: Key) -> Int? {
        guard let number = lenientDouble(key), abs(number) < 9e15 else { return nil }
        return Int(number.rounded(.down))
    }

    func lenientBool(_ key: Key) -> Bool? {
        guard let value = try? decodeIfPresent(JSONValue.self, forKey: key) else { return nil }
        switch value {
        case .bool(let bool): return bool
        case .string(let string): return ["true", "1", "yes"].contains(string.lowercased()) ? true
            : ["false", "0", "no"].contains(string.lowercased()) ? false : nil
        case .number(let number): return number != 0
        default: return nil
        }
    }

    func lenientDate(_ key: Key) -> Date? {
        FlexibleDate.date(from: try? decodeIfPresent(JSONValue.self, forKey: key))
    }

    /// Drops malformed entries instead of failing the whole array.
    func lenientLimits(_ key: Key) -> [UsageLimit] {
        guard let values = try? decodeIfPresent([JSONValue].self, forKey: key) else { return [] }
        return values.compactMap { try? $0.decode(UsageLimit.self) }
    }
}
