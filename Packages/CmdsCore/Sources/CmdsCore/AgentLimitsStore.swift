import Foundation

/// The newest account limits of agents that report them only while they run, kept across launches in the support
/// directory: Codex (`codex-limits.json`, #227: only in the session files of running sessions) and Antigravity
/// (`antigravity-limits.json`, #290: only while an interactive agy runs). Without this they would be unknown after a
/// relaunch until the agent runs again. Written when the figures change; at launch only the windows that have not
/// reset are taken (`AgentLimits.active(at:)`), and a file with none left is ignored. `agent` picks the file; Codex is
/// the default.
public enum AgentLimitsStore {
    public static let fileName = "codex-limits.json"

    /// The agents whose limits are kept.
    public static let agents: [AgentKind] = [.codex, .antigravity]

    public static func fileName(for agent: AgentKind) -> String {
        agent == .codex ? fileName : "\(agent.rawValue)-limits.json"
    }

    public static func url(supportDirectory: URL, agent: AgentKind = .codex) -> URL {
        supportDirectory.appendingPathComponent(fileName(for: agent))
    }

    public static func encode(_ limits: AgentLimits) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(limits)
    }

    /// The stored limits still in effect at `now`; nil for another agent, a damaged file or when every window has reset.
    public static func decode(_ data: Data, agent: AgentKind = .codex, now: Date = Date()) -> AgentLimits? {
        guard let limits = try? JSONDecoder().decode(AgentLimits.self, from: data), limits.agent == agent else { return nil }
        return limits.active(at: now)
    }

    public static func load(supportDirectory: URL, agent: AgentKind = .codex, now: Date = Date()) -> AgentLimits? {
        guard let data = try? Data(contentsOf: url(supportDirectory: supportDirectory, agent: agent)) else { return nil }
        return decode(data, agent: agent, now: now)
    }

    public static func save(_ limits: AgentLimits, supportDirectory: URL) throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try encode(limits).write(to: url(supportDirectory: supportDirectory, agent: limits.agent), options: .atomic)
    }

    /// The figures differ: worth writing. `updatedAt` counts only while a reached limit has no reset time, since it
    /// is what that limit expires from (`AgentLimits.unknownResetLifetime`, #231).
    public static func changed(_ old: AgentLimits?, _ new: AgentLimits) -> Bool {
        old?.limits != new.limits || old?.plan != new.plan
            || (new.hasUnknownReset && old?.updatedAt != new.updatedAt)
    }
}
