import CmdsCore
import Foundation

// UI text for values that come from CmdsCore, compiled into both apps (Mac and iOS), so each app's
// Localizable.xcstrings gets these keys. CmdsCore itself stays English for the CLI and the socket API
// (docs/internals/localization.md).

extension AgentFormat.Strings {
    /// Agent usage text (sidebar, tooltips, phone) in the app's language. The keys are `AgentFormat.Text.english`.
    static let localized = AgentFormat.Strings(locale: Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")) {
        localizedAgentText($0)
    }
}

private func localizedAgentText(_ text: AgentFormat.Text) -> String {
    switch text {
    case .durationSeconds(let s): return String(localized: "\(s)s", comment: "duration: seconds (42s)")
    case .durationMinutes(let m): return String(localized: "\(m)m", comment: "duration: minutes (48m)")
    case .durationHoursMinutes(let h, let m): return String(localized: "\(h)h\(m)m", comment: "duration: hours and minutes (3h25m)")
    case .durationDaysHours(let d, let h): return String(localized: "\(d)d\(h)h", comment: "duration: days and hours (2d3h)")
    case .justNow: return String(localized: "just now", comment: "age of agent figures")
    case .secondsAgo(let s): return String(localized: "\(s)s ago", comment: "age of agent figures")
    case .minutesAgo(let m): return String(localized: "\(m) min ago", comment: "age of agent figures")
    case .hoursAgo(let h): return String(localized: "\(h) h ago", comment: "age of agent figures")
    case .daysAgo(let d): return String(localized: "\(d) d ago", comment: "age of agent figures")
    case .inDuration(let d): return String(localized: " (in \(d))", comment: "after a limit's reset time: 15:30 (in 2h10m)")
    case .spendLabel: return String(localized: "spend", comment: "short label of an agent's spend limit (spend $12/$50)")
    case .fiveHourLimit: return String(localized: "5-hour limit", comment: "agent usage limit")
    case .sevenDayLimit: return String(localized: "7-day limit", comment: "agent usage limit")
    case .spendLimit: return String(localized: "Spend limit", comment: "agent usage limit")
    case .windowLimit(let label): return String(localized: "\(label) limit", comment: "agent usage limit of a window (1h limit)")
    case .limitUsed(let title, let percent):
        return String(localized: "\(title) \(percent) used", comment: "agent usage limit: 5-hour limit 40% used")
    case .spendUsed(let title, let used, let limit, let percent):
        return String(localized: "\(title) \(used) of \(limit) (\(percent))", comment: "Spend limit $12.00 of $50.00 (24%)")
    case .spendPeriod(let period):
        switch period {
        case "daily": return String(localized: " daily", comment: "after a spend limit: its period")
        case "weekly": return String(localized: " weekly", comment: "after a spend limit: its period")
        case "monthly": return String(localized: " monthly", comment: "after a spend limit: its period")
        default: return " \(period)"
        }
    case .resets(let time): return String(localized: " · resets \(time)", comment: "after an agent usage limit")
    case .windowElapsed(let percent):
        return String(localized: " · \(percent) of the window elapsed", comment: "after an agent usage limit")
    case .context: return String(localized: "Context", comment: "agent context window")
    case .contextPercent(let percent): return String(localized: "Context \(percent)", comment: "agent context window: Context 53%")
    case .contextTokens(let used): return String(localized: " · \(used) tokens", comment: "after Context 53%")
    case .contextTokensOf(let used, let window):
        return String(localized: " · \(used) of \(window) tokens", comment: "after Context 53%: 527k of 1M tokens")
    case .contextOver200k: return String(localized: " · over 200k", comment: "after Context: more than 200k tokens")
    case .cost(let cost): return String(localized: "Cost \(cost)", comment: "agent session cost")
    case .costPerHour(let rate): return String(localized: " · \(rate)/h", comment: "after Cost: cost per hour")
    case .session(let duration): return String(localized: "Session \(duration)", comment: "agent session length")
    case .apiDuration(let duration): return String(localized: " · API \(duration)", comment: "after Session: time in API calls")
    case .apiShare(let percent): return String(localized: " (\(percent)% of wall time)", comment: "after the API time")
    case .lines(let added, let removed): return String(localized: "Lines +\(added) −\(removed)", comment: "lines changed by the agent")
    case .promptCache(let percent): return String(localized: "Prompt cache \(percent) hits", comment: "prompt cache hit ratio")
    case .cacheWarm: return String(localized: " · warm", comment: "prompt cache still alive")
    case .cacheCold: return String(localized: " · cold", comment: "prompt cache expired")
    case .tokens: return String(localized: "Tokens", comment: "agent token totals")
    case .tokensIn(let count): return String(localized: " \(count) in", comment: "after Tokens: input tokens")
    case .tokensCached(let count): return String(localized: " (\(count) cached)", comment: "after the input tokens")
    case .tokensOut(let count): return String(localized: " · \(count) out", comment: "after Tokens: output tokens")
    case .tokensReasoning(let count): return String(localized: " (\(count) reasoning)", comment: "after the output tokens")
    case .updated(let age): return String(localized: "Updated \(age)")
    case .idle: return String(localized: " (idle)")
    }
}

extension MemoryPressure {
    /// `name` stays English for the API and CLI; this is for the UI.
    var localizedName: String {
        switch self {
        case .normal: return String(localized: "normal", comment: "memory pressure")
        case .warning: return String(localized: "warning", comment: "memory pressure")
        case .critical: return String(localized: "critical", comment: "memory pressure")
        case .unknown: return String(localized: "unknown", comment: "memory pressure")
        }
    }
}

/// Default pane and workspace titles. The model, the socket API and the sync protocol keep them English
/// ("Terminal", "Browser", "Workspace"); the UI shows them translated.
enum DefaultTitle {
    static func localized(_ title: String) -> String {
        switch title {
        case "Terminal": return String(localized: "Terminal", comment: "default pane title")
        case "Browser": return String(localized: "Browser", comment: "default pane title")
        case "Workspace": return String(localized: "Workspace", comment: "default workspace title")
        default: return title
        }
    }
}
