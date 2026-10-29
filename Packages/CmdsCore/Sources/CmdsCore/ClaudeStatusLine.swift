import Foundation

/// Turns the JSON Claude Code passes to its status-line command into an `AgentUsage` (`cmds hook claude-status`).
///
/// Read leniently, since any field may be missing or change type between versions: `model.display_name`,
/// `effort.level`, `session_id`, `context_window.{used_percentage, context_window_size, total_input_tokens}`,
/// `exceeds_200k_tokens`, `cost.{total_cost_usd, total_duration_ms, total_api_duration_ms, total_lines_added,
/// total_lines_removed}`, `prompt_cache.{hit_ratio, warm}` and `rate_limits.{five_hour, seven_day, spend_limit, …}`
/// (`used_percentage`, `resets_at` as epoch seconds/ms or ISO 8601, spend: `used_usd`, `limit_usd`, `period`).
/// Nothing else (paths, transcript, workspace) is kept.
public enum ClaudeStatusLine {
    /// nil when the input is not a JSON object or carries none of the known figures.
    public static func usage(fromJSON data: Data, now: Date = Date()) -> AgentUsage? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data), case .object = root else { return nil }
        var usage = AgentUsage(agent: .claude, updatedAt: now)
        usage.model = string(root["model"]?["display_name"]) ?? string(root["model"]?["id"]) ?? string(root["model"])
        usage.effort = string(root["effort"]?["level"]) ?? string(root["effort"])
        usage.sessionID = string(root["session_id"])

        let context = root["context_window"]
        usage.contextWindow = int(context?["context_window_size"]).flatMap { $0 > 0 ? $0 : nil }
        usage.contextUsedPercent = number(context?["used_percentage"])
        var tokens = int(context?["total_input_tokens"])
        if (tokens ?? 0) == 0, let window = usage.contextWindow, let percent = usage.contextUsedPercent {
            tokens = Int(Double(window) * percent / 100)
        }
        usage.contextTokens = tokens
        if usage.contextUsedPercent == nil, let tokens, let window = usage.contextWindow {
            usage.contextUsedPercent = Double(tokens) / Double(window) * 100
        }
        usage.contextOver200k = bool(root["exceeds_200k_tokens"])

        let cost = root["cost"]
        usage.costUSD = number(cost?["total_cost_usd"])
        usage.sessionDurationMs = int(cost?["total_duration_ms"])
        usage.apiDurationMs = int(cost?["total_api_duration_ms"])
        usage.linesAdded = int(cost?["total_lines_added"])
        usage.linesRemoved = int(cost?["total_lines_removed"])

        if let ratio = number(root["prompt_cache"]?["hit_ratio"]) { usage.cacheHitRatio = ratio > 1 ? ratio / 100 : ratio }
        usage.cacheWarm = bool(root["prompt_cache"]?["warm"])
        usage.limits = limits(root["rate_limits"])

        let known = usage.model != nil || usage.costUSD != nil || usage.contextUsedPercent != nil
            || usage.sessionDurationMs != nil || !usage.limits.isEmpty
        return known ? usage : nil
    }

    /// `five_hour`, `seven_day`, then `spend_limit` (as `spend`), then any other window with `used_percentage`.
    static func limits(_ value: JSONValue?) -> [UsageLimit] {
        guard case .object(let windows)? = value else { return [] }
        let preferred = [UsageLimit.fiveHour, UsageLimit.sevenDay, "spend_limit"]
        let keys = preferred.filter { windows[$0] != nil } + windows.keys.filter { !preferred.contains($0) }.sorted()
        return keys.compactMap { key -> UsageLimit? in
            guard let window = windows[key], case .object = window else { return nil }
            let usedUSD = number(window["used_usd"])
            let limitUSD = number(window["limit_usd"])
            var used = number(window["used_percentage"])
            if used == nil, let usedUSD, let limitUSD, limitUSD > 0 { used = usedUSD / limitUSD * 100 }
            guard let used else { return nil }
            let id = key == "spend_limit" ? UsageLimit.spend : key
            return UsageLimit(id: id, usedPercent: used, resetsAt: FlexibleDate.date(from: window["resets_at"]),
                              windowMinutes: int(window["window_minutes"]), usedUSD: usedUSD, limitUSD: limitUSD,
                              period: string(window["period"]))
        }
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .number(let number)?: return number.isFinite ? number : nil
        case .string(let string)?: return Double(string.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        default: return nil
        }
    }

    private static func int(_ value: JSONValue?) -> Int? {
        guard let number = number(value), abs(number) < 9e15 else { return nil }
        return Int(number.rounded(.down))
    }

    private static func bool(_ value: JSONValue?) -> Bool? {
        switch value {
        case .bool(let bool)?: return bool
        case .string(let string)?: return string == "true" ? true : string == "false" ? false : nil
        default: return nil
        }
    }
}
