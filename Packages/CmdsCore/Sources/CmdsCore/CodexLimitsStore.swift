import Foundation

/// The newest Codex account limits, kept across launches (`codex-limits.json` in the support directory, #227): Codex
/// reports them only in the session files of running sessions, so without this they would be unknown after a
/// relaunch until a Codex runs again. Written when the figures change; at launch only the windows that have not
/// reset are taken (`AgentLimits.active(at:)`), and a file with none left is ignored.
public enum CodexLimitsStore {
    public static let fileName = "codex-limits.json"

    public static func url(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent(fileName)
    }

    public static func encode(_ limits: AgentLimits) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(limits)
    }

    /// The stored limits still in effect at `now`; nil for another agent, a damaged file or when every window has reset.
    public static func decode(_ data: Data, now: Date = Date()) -> AgentLimits? {
        guard let limits = try? JSONDecoder().decode(AgentLimits.self, from: data), limits.agent == .codex else { return nil }
        return limits.active(at: now)
    }

    public static func load(supportDirectory: URL, now: Date = Date()) -> AgentLimits? {
        guard let data = try? Data(contentsOf: url(supportDirectory: supportDirectory)) else { return nil }
        return decode(data, now: now)
    }

    public static func save(_ limits: AgentLimits, supportDirectory: URL) throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try encode(limits).write(to: url(supportDirectory: supportDirectory), options: .atomic)
    }

    /// The figures differ: worth writing. `updatedAt` counts only while a reached limit has no reset time, since it
    /// is what that limit expires from (`AgentLimits.unknownResetLifetime`, #231).
    public static func changed(_ old: AgentLimits?, _ new: AgentLimits) -> Bool {
        old?.limits != new.limits || old?.plan != new.plan
            || (new.hasUnknownReset && old?.updatedAt != new.updatedAt)
    }
}
