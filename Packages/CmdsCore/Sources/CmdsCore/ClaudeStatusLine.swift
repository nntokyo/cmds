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
        usage.model = StatusLineJSON.string(root["model"]?["display_name"]) ?? StatusLineJSON.string(root["model"]?["id"]) ?? StatusLineJSON.string(root["model"])
        usage.effort = StatusLineJSON.string(root["effort"]?["level"]) ?? StatusLineJSON.string(root["effort"])
        usage.sessionID = StatusLineJSON.string(root["session_id"])

        let context = root["context_window"]
        usage.contextWindow = StatusLineJSON.int(context?["context_window_size"]).flatMap { $0 > 0 && $0 < 1 << 40 ? $0 : nil }
        usage.contextUsedPercent = StatusLineJSON.number(context?["used_percentage"]).map { min(max($0, 0), 100) }
        var tokens = StatusLineJSON.int(context?["total_input_tokens"])
        if (tokens ?? 0) == 0, let window = usage.contextWindow, let percent = usage.contextUsedPercent {
            tokens = Int(Double(window) * percent / 100)
        }
        usage.contextTokens = tokens
        if usage.contextUsedPercent == nil, let tokens, let window = usage.contextWindow {
            usage.contextUsedPercent = Double(tokens) / Double(window) * 100
        }
        usage.contextOver200k = StatusLineJSON.bool(root["exceeds_200k_tokens"])

        let cost = root["cost"]
        usage.costUSD = StatusLineJSON.number(cost?["total_cost_usd"])
        usage.sessionDurationMs = StatusLineJSON.int(cost?["total_duration_ms"])
        usage.apiDurationMs = StatusLineJSON.int(cost?["total_api_duration_ms"])
        usage.linesAdded = StatusLineJSON.int(cost?["total_lines_added"])
        usage.linesRemoved = StatusLineJSON.int(cost?["total_lines_removed"])

        if let ratio = StatusLineJSON.number(root["prompt_cache"]?["hit_ratio"]) { usage.cacheHitRatio = ratio > 1 ? ratio / 100 : ratio }
        usage.cacheWarm = StatusLineJSON.bool(root["prompt_cache"]?["warm"])
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
            let usedUSD = StatusLineJSON.number(window["used_usd"])
            let limitUSD = StatusLineJSON.number(window["limit_usd"])
            var used = StatusLineJSON.number(window["used_percentage"])
            if used == nil, let usedUSD, let limitUSD, limitUSD > 0 { used = usedUSD / limitUSD * 100 }
            guard let used else { return nil }
            let id = key == "spend_limit" ? UsageLimit.spend : key
            return UsageLimit(id: id, usedPercent: used, resetsAt: FlexibleDate.date(from: window["resets_at"]),
                              windowMinutes: StatusLineJSON.int(window["window_minutes"]), usedUSD: usedUSD, limitUSD: limitUSD,
                              period: StatusLineJSON.string(window["period"]))
        }
    }
}
