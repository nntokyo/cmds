import Foundation

/// How full a context window or account limit is: ≥ 80 % warning, ≥ 95 % critical.
public enum UsageLevel: Int, Comparable, Sendable {
    case normal
    case warning
    case critical

    public init(percent: Double?) {
        guard let percent, percent.isFinite else {
            self = .normal
            return
        }
        self = percent >= 95 ? .critical : percent >= 80 ? .warning : .normal
    }

    public static func < (lhs: UsageLevel, rhs: UsageLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Text for agent usage, shared by the sidebar, the CLI and the phone. English by default (CLI, API); the apps pass
/// `strings:` for their language. Mirrors the figures of Claude Code's
/// status line (`ctx 53% 527k/1M │ $117.99 ($34.44/h) │ ⏱ 3h25m api 3h40m(107%) │ +17642 -330 │ cache ●98%`).
public enum AgentFormat {
    /// One run of `summaryParts`; `level` colours values (context, limits).
    public struct Part: Equatable, Sendable {
        public enum Style: Sendable { case name, label, value, separator }
        public var text: String
        public var style: Style
        public var level: UsageLevel

        public init(_ text: String, _ style: Style, level: UsageLevel = .normal) {
            self.text = text
            self.style = style
            self.level = level
        }
    }

    // MARK: Numbers

    /// `950`, `12k`, `527k`, `1M`, `1.5M`.
    public static func tokens(_ count: Int) -> String {
        let count = min(max(0, count), 1 << 50)
        if count >= 999_500 {
            let tenths = (count + 50_000) / 100_000
            return tenths % 10 == 0 ? "\(tenths / 10)M" : "\(tenths / 10).\(tenths % 10)M"
        }
        if count >= 1000 { return "\((count + 500) / 1000)k" }
        return "\(count)"
    }

    /// `42s` under a minute, `48m`, `3h25m`, `2d3h`.
    public static func duration(milliseconds: Int, strings: Strings = .english) -> String {
        let seconds = max(0, milliseconds / 1000)
        if seconds < 60 { return strings(.durationSeconds(seconds)) }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours >= 24 { return strings(.durationDaysHours(hours / 24, hours % 24)) }
        if hours > 0 { return strings(.durationHoursMinutes(hours, minutes)) }
        return strings(.durationMinutes(minutes))
    }

    /// `$0.42`, `$117.99`, `$1234` (no cents from $1000).
    public static func usd(_ value: Double) -> String {
        guard value.isFinite else { return "–" }
        return abs(value) >= 1000 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }

    /// Whole percent: `0%`, `53%`, `107%`.
    public static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "–" }
        return String(format: "%.0f%%", max(0, value))
    }

    /// Cost per hour of session time; nil for sessions under a minute.
    public static func hourlyRate(_ usage: AgentUsage) -> Double? {
        guard let cost = usage.costUSD, let ms = usage.sessionDurationMs, ms >= 60_000 else { return nil }
        return cost * 3_600_000 / Double(ms)
    }

    // MARK: Names

    /// `Claude Opus 4.5`, `Codex gpt-5-codex`, or just the agent name without a model.
    public static func name(_ usage: AgentUsage) -> String {
        let agent = usage.agent.displayName
        guard let model = usage.model?.trimmingCharacters(in: .whitespaces), !model.isEmpty else { return agent }
        if model.lowercased().hasPrefix(agent.lowercased()) { return model }
        return "\(agent) \(model)"
    }

    /// `5h`, `7d`, `spend`, or the window length (`1h`, `30m`).
    /// `5h`/`7d` stay as they are in every language (short, like Claude's own usage screen); `spend` is translated.
    public static func limitLabel(_ limit: UsageLimit, strings: Strings = .english) -> String {
        switch limit.id {
        case UsageLimit.fiveHour: return "5h"
        case UsageLimit.sevenDay: return "7d"
        case UsageLimit.spend: return strings(.spendLabel)
        default:
            if let minutes = limit.windowMinutes, minutes > 0 {
                if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
                if minutes % 60 == 0 { return "\(minutes / 60)h" }
                return "\(minutes)m"
            }
            return limit.id.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// `5-hour limit`, `7-day limit`, `Spend limit`.
    public static func limitTitle(_ limit: UsageLimit, strings: Strings = .english) -> String {
        switch limit.id {
        case UsageLimit.fiveHour: return strings(.fiveHourLimit)
        case UsageLimit.sevenDay: return strings(.sevenDayLimit)
        case UsageLimit.spend: return strings(.spendLimit)
        default:
            let label = limitLabel(limit, strings: strings)
            return label.first?.isNumber == true ? strings(.windowLimit(label)) : label.prefix(1).uppercased() + label.dropFirst()
        }
    }

    /// `40%`, or `$12/$50` for a spend limit with amounts.
    public static func limitValue(_ limit: UsageLimit) -> String {
        if limit.id == UsageLimit.spend, let used = limit.usedUSD, let cap = limit.limitUSD {
            return String(format: "$%.0f/$%.0f", used, cap)
        }
        return percent(limit.usedPercent)
    }

    // MARK: Lines

    /// `Claude Opus · ctx 53% · $117.99 · 5h 40%`: name, context, cost and the 5-hour (else first) window of `limits`
    /// (default: the session's own).
    /// `ctx` and the window labels stay short in every language (see `limitLabel`).
    public static func summaryParts(_ usage: AgentUsage, limits: [UsageLimit]? = nil, strings: Strings = .english) -> [Part] {
        var parts = [Part(name(usage), .name)]
        func add(_ label: String?, _ value: String, level: UsageLevel = .normal) {
            parts.append(Part(" · ", .separator))
            if let label { parts.append(Part(label + " ", .label)) }
            parts.append(Part(value, .value, level: level))
        }
        if let context = usage.contextUsedPercent {
            add("ctx", percent(context), level: UsageLevel(percent: context))
        }
        if let cost = usage.costUSD { add(nil, usd(cost)) }
        let windows = limits ?? usage.limits
        if let window = windows.first(where: { $0.id == UsageLimit.fiveHour }) ?? windows.first(where: { $0.id != UsageLimit.spend }) {
            add(limitLabel(window, strings: strings), percent(window.usedPercent), level: UsageLevel(percent: window.usedPercent))
        }
        return parts
    }

    public static func summary(_ usage: AgentUsage, limits: [UsageLimit]? = nil, strings: Strings = .english) -> String {
        summaryParts(usage, limits: limits, strings: strings).map(\.text).joined()
    }

    /// The session figures in the order of Claude Code's status line (only those that are known).
    public static func statusLine(_ usage: AgentUsage) -> String {
        var segments: [String] = []
        if usage.contextUsedPercent != nil || usage.contextTokens != nil {
            var text = "ctx"
            if let context = usage.contextUsedPercent { text += " " + percent(context) }
            if let used = usage.contextTokens {
                text += " " + tokens(used)
                if let window = usage.contextWindow, window > 0 { text += "/" + tokens(window) }
            }
            if usage.contextOver200k == true { text += " >200k" }
            segments.append(text)
        }
        if let cost = usage.costUSD {
            var text = usd(cost)
            if let rate = hourlyRate(usage) { text += " (\(usd(rate))/h)" }
            segments.append(text)
        }
        if let ms = usage.sessionDurationMs {
            var text = "⏱ " + duration(milliseconds: ms)
            if let api = usage.apiDurationMs, api > 0 {
                text += " api " + duration(milliseconds: api)
                if ms > 0 { text += "(\(Int((Double(api) * 100 / Double(ms)).rounded(.down)))%)" }
            }
            segments.append(text)
        }
        if usage.linesAdded != nil || usage.linesRemoved != nil {
            segments.append("+\(usage.linesAdded ?? 0) -\(usage.linesRemoved ?? 0)")
        }
        if let ratio = usage.cacheHitRatio {
            segments.append("cache \(usage.cacheWarm == true ? "●" : "○")\(percent(ratio * 100))")
        }
        if let tokenText = tokenTotals(usage) { segments.append(tokenText) }
        return segments.joined(separator: " │ ")
    }

    /// `tokens 117k in (80k cached) · 487 out` from session totals (Codex).
    public static func tokenTotals(_ usage: AgentUsage) -> String? {
        guard usage.inputTokens != nil || usage.outputTokens != nil else { return nil }
        var text = "tokens"
        if let input = usage.inputTokens {
            text += " \(tokens(input)) in"
            if let cached = usage.cachedInputTokens, cached > 0 { text += " (\(tokens(cached)) cached)" }
        }
        if let output = usage.outputTokens { text += " · \(tokens(output)) out" }
        return text
    }

    /// `5h 40% · 7d 12% · spend $12/$50`.
    public static func limitsSummary(_ limits: [UsageLimit], strings: Strings = .english) -> String {
        AgentLimits(agent: .other, limits: limits).ordered
            .map { "\(limitLabel($0, strings: strings)) \(limitValue($0))" }.joined(separator: " · ")
    }

    // MARK: Tooltips

    /// Multi-line description of one pane's agent (sidebar tooltip, phone detail).
    public static func detailLines(_ usage: AgentUsage, now: Date = Date(), strings: Strings = .english) -> [String] {
        func duration(_ ms: Int) -> String { AgentFormat.duration(milliseconds: ms, strings: strings) }
        var lines: [String] = []
        var title = name(usage)
        if let effort = usage.effort { title += " (\(effort))" }
        lines.append(title)
        if usage.contextUsedPercent != nil || usage.contextTokens != nil {
            var text = usage.contextUsedPercent.map { strings(.contextPercent(percent($0))) } ?? strings(.context)
            if let used = usage.contextTokens {
                if let window = usage.contextWindow, window > 0 {
                    text += strings(.contextTokensOf(tokens(used), tokens(window)))
                } else {
                    text += strings(.contextTokens(tokens(used)))
                }
            }
            if usage.contextOver200k == true { text += strings(.contextOver200k) }
            lines.append(text)
        }
        if let cost = usage.costUSD {
            var text = strings(.cost(usd(cost)))
            if let rate = hourlyRate(usage) { text += strings(.costPerHour(usd(rate))) }
            lines.append(text)
        }
        if let ms = usage.sessionDurationMs {
            var text = strings(.session(duration(ms)))
            if let api = usage.apiDurationMs, api > 0 {
                text += strings(.apiDuration(duration(api)))
                if ms > 0 { text += strings(.apiShare(Int((Double(api) * 100 / Double(ms)).rounded(.down)))) }
            }
            lines.append(text)
        }
        if usage.linesAdded != nil || usage.linesRemoved != nil {
            lines.append(strings(.lines(added: usage.linesAdded ?? 0, removed: usage.linesRemoved ?? 0)))
        }
        if let ratio = usage.cacheHitRatio {
            var text = strings(.promptCache(percent(ratio * 100)))
            if let warm = usage.cacheWarm { text += strings(warm ? .cacheWarm : .cacheCold) }
            lines.append(text)
        }
        if usage.inputTokens != nil || usage.outputTokens != nil {
            var text = strings(.tokens)
            if let input = usage.inputTokens {
                text += strings(.tokensIn(tokens(input)))
                if let cached = usage.cachedInputTokens, cached > 0 { text += strings(.tokensCached(tokens(cached))) }
            }
            if let output = usage.outputTokens { text += strings(.tokensOut(tokens(output))) }
            if let reasoning = usage.reasoningTokens, reasoning > 0 { text += strings(.tokensReasoning(tokens(reasoning))) }
            lines.append(text)
        }
        var updated = strings(.updated(age(usage.updatedAt, now: now, strings: strings)))
        if usage.isStale { updated += strings(.idle) }
        lines.append(updated)
        return lines
    }

    /// One line per window: `5-hour limit 40% used · resets 15:30 (in 2h10m) · 62% of the window elapsed`.
    public static func limitLines(_ limits: [UsageLimit], now: Date = Date(), strings: Strings = .english) -> [String] {
        AgentLimits(agent: .other, limits: limits).ordered.map { limit in
            let title = limitTitle(limit, strings: strings)
            var text: String
            if limit.id == UsageLimit.spend, let used = limit.usedUSD, let cap = limit.limitUSD {
                text = strings(.spendUsed(title: title, used: String(format: "$%.2f", used),
                                          limit: String(format: "$%.2f", cap), percent: percent(limit.usedPercent)))
                if let period = limit.period { text += strings(.spendPeriod(period)) }
            } else {
                text = strings(.limitUsed(title: title, percent: percent(limit.usedPercent)))
            }
            if let resetsAt = limit.resetsAt { text += strings(.resets(resetTime(resetsAt, now: now, strings: strings))) }
            if limit.id != UsageLimit.spend, let elapsed = limit.elapsedPercent(at: now) {
                text += strings(.windowElapsed(percent(elapsed)))
            }
            return text
        }
    }

    /// `15:30 (in 2h10m)` today or within a day, `Fri 09:00` within a week, else `10/31 09:00`.
    public static func resetTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                                 strings: Strings = .english) -> String {
        let formatter = DateFormatter()
        formatter.locale = strings.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let interval = date.timeIntervalSince(now)
        if calendar.isDate(date, inSameDayAs: now) || (interval >= 0 && interval < 6 * 3600) {
            formatter.dateFormat = "HH:mm"
        } else if interval >= 0 && interval < 6 * 86400 {
            formatter.dateFormat = "EEE HH:mm"
        } else {
            formatter.dateFormat = "M/d HH:mm"
        }
        var text = formatter.string(from: date)
        if interval > 0 && interval < 86400 {
            text += strings(.inDuration(duration(milliseconds: Int(interval * 1000), strings: strings)))
        }
        return text
    }

    /// `just now`, `42s ago`, `3 min ago`, `2 h ago`, `3 d ago`.
    public static func age(_ date: Date, now: Date = Date(), strings: Strings = .english) -> String {
        let seconds = Int(now.timeIntervalSince(date).rounded(.down))
        if seconds < 5 { return strings(.justNow) }
        if seconds < 60 { return strings(.secondsAgo(seconds)) }
        if seconds < 3600 { return strings(.minutesAgo(seconds / 60)) }
        if seconds < 86400 { return strings(.hoursAgo(seconds / 3600)) }
        return strings(.daysAgo(seconds / 86400))
    }
}
