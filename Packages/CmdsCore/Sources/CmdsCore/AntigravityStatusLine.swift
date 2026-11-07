import Foundation

/// Google Antigravity's CLI (`agy`) status-line JSON → `AgentUsage` (used by `cmds hook agy-status`). The CLI passes
/// its custom status-line command a JSON much like Claude Code's: `model` (`display_name`, `effort`),
/// `context_window` (`used_percentage`, `context_window_size`, `total_input_tokens`, …), `conversation_id`, `cost`,
/// `plan_tier`, and `quota`: one window per model group (`gemini-5h`, `gemini-weekly`, `3p-5h`, …) with
/// `remaining_fraction` (0–1) and `reset_time`. Checked with agy 1.5.2. Other fields (`email`, paths) are not read.
public enum AntigravityStatusLine {
    public static func usage(fromJSON data: Data, now: Date = Date()) -> AgentUsage? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data), case .object = root else { return nil }
        typealias Read = ClaudeStatusLine
        var usage = AgentUsage(agent: .antigravity, updatedAt: now)
        usage.model = Read.string(root["model"]?["display_name"]) ?? Read.string(root["model"]?["id"])
        usage.effort = Read.string(root["model"]?["effort"])
        usage.sessionID = Read.string(root["conversation_id"]) ?? Read.string(root["session_id"])

        let context = root["context_window"]
        usage.contextWindow = Read.int(context?["context_window_size"]).flatMap { $0 > 0 && $0 < 1 << 40 ? $0 : nil }
        usage.contextUsedPercent = Read.number(context?["used_percentage"]).map { min(max($0, 0), 100) }
        usage.contextTokens = Read.int(context?["total_input_tokens"])
        usage.outputTokens = Read.int(context?["total_output_tokens"])
        usage.costUSD = Read.number(root["cost"]) ?? Read.number(root["cost"]?["total_cost_usd"])
        usage.plan = Read.string(root["plan_tier"])
        usage.limits = limits(root["quota"])

        let known = usage.model != nil || usage.contextUsedPercent != nil || !usage.limits.isEmpty
        return known ? usage : nil
    }

    /// `quota` windows as limits, ids as reported (`gemini-5h`): Gemini's own windows first (shortest first), then the
    /// other model groups (`gemini-argon-…`), then third-party models (`3p-…`).
    static func limits(_ value: JSONValue?) -> [UsageLimit] {
        guard case .object(let windows)? = value else { return [] }
        func rank(_ id: String) -> (Int, Int, String) {
            let group = id.hasPrefix("3p-") ? 2 : groupName(id) == "Gemini" ? 0 : 1
            return (group, windowMinutes(id) ?? Int.max, id)
        }
        return windows.keys.sorted { rank($0) < rank($1) }.compactMap { key -> UsageLimit? in
            guard let window = windows[key], let remaining = ClaudeStatusLine.number(window["remaining_fraction"]) else {
                return nil
            }
            return UsageLimit(id: key, usedPercent: min(max((1 - remaining) * 100, 0), 100),
                              resetsAt: FlexibleDate.date(from: window["reset_time"]),
                              windowMinutes: windowMinutes(key))
        }
    }

    /// `…-5h` → 300, `…-weekly` → 7 days, `…-daily` → 1 day; nil for other names.
    static func windowMinutes(_ id: String) -> Int? {
        guard let suffix = id.split(separator: "-").last else { return nil }
        switch suffix {
        case "weekly": return 7 * 1440
        case "daily": return 1440
        default:
            guard suffix.hasSuffix("h"), let hours = Int(suffix.dropLast()), hours > 0 else { return nil }
            return hours * 60
        }
    }

    /// The model group of a window id, for its label: `gemini-5h` → `Gemini`, `3p-weekly` → `3P`,
    /// `gemini-argon-wtu-weekly` → `Argon`; nil when the id has no group.
    public static func groupName(_ id: String) -> String? {
        var parts = id.split(separator: "-").map(String.init)
        guard parts.count >= 2, windowMinutes(id) != nil else { return nil }
        parts.removeLast()
        if parts == ["gemini"] { return "Gemini" }
        if parts.count > 1, parts.first == "gemini" { parts.removeFirst() }
        guard let name = parts.first, !name.isEmpty else { return nil }
        return name.count <= 2 ? name.uppercased() : name.prefix(1).uppercased() + name.dropFirst()
    }
}
