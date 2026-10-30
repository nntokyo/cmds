import Foundation

extension AgentFormat {
    /// The words and templates of `AgentFormat`'s text. `.english` (the default everywhere) is what the CLI, the
    /// socket API and the tests use, and must not change (scripts read it). The apps pass their own, built from
    /// their String Catalogs (`AgentFormat.Strings.localized` in `Shared/Sources`; docs/internals/localization.md).
    public struct Strings: Sendable {
        /// Locale of dates (`Fri 09:00`).
        public var locale: Locale
        public var text: @Sendable (Text) -> String

        public init(locale: Locale, text: @escaping @Sendable (Text) -> String) {
            self.locale = locale
            self.text = text
        }

        public static let english = Strings(locale: Locale(identifier: "en_US_POSIX")) { $0.english }

        func callAsFunction(_ text: Text) -> String { self.text(text) }
    }

    /// One piece of text. Pieces that start with a space or ` · ` are appended to the one before.
    public enum Text: Equatable, Sendable {
        // Durations: `42s`, `48m`, `3h25m`, `2d3h`.
        case durationSeconds(Int)
        case durationMinutes(Int)
        case durationHoursMinutes(Int, Int)
        case durationDaysHours(Int, Int)
        // Ages: `just now`, `42s ago`, `3 min ago`, `2 h ago`, `3 d ago`.
        case justNow
        case secondsAgo(Int)
        case minutesAgo(Int)
        case hoursAgo(Int)
        case daysAgo(Int)
        /// ` (in 2h10m)` after a reset time.
        case inDuration(String)
        /// Short label of the spend limit (`spend $12/$50`).
        case spendLabel
        // Limit titles.
        case fiveHourLimit
        case sevenDayLimit
        case spendLimit
        /// `1h limit` (other windows).
        case windowLimit(String)
        // Limit lines: `5-hour limit 40% used · resets 15:30 (in 2h10m) · 62% of the window elapsed`.
        case limitUsed(title: String, percent: String)
        case spendUsed(title: String, used: String, limit: String, percent: String)
        /// ` monthly` after a spend limit (the period as Claude reports it).
        case spendPeriod(String)
        case resets(String)
        case windowElapsed(String)
        // Detail lines (tooltip of a pane's agent).
        case context
        case contextPercent(String)
        case contextTokens(String)
        case contextTokensOf(String, String)
        case contextOver200k
        case cost(String)
        case costPerHour(String)
        case session(String)
        case apiDuration(String)
        case apiShare(Int)
        case lines(added: Int, removed: Int)
        case promptCache(String)
        case cacheWarm
        case cacheCold
        case tokens
        case tokensIn(String)
        case tokensCached(String)
        case tokensOut(String)
        case tokensReasoning(String)
        case updated(String)
        case idle

        /// The CLI/API text. The apps' catalogs use these as keys (with `%@`/`%lld` for the values).
        public var english: String {
            switch self {
            case .durationSeconds(let s): return "\(s)s"
            case .durationMinutes(let m): return "\(m)m"
            case .durationHoursMinutes(let h, let m): return "\(h)h\(m)m"
            case .durationDaysHours(let d, let h): return "\(d)d\(h)h"
            case .justNow: return "just now"
            case .secondsAgo(let s): return "\(s)s ago"
            case .minutesAgo(let m): return "\(m) min ago"
            case .hoursAgo(let h): return "\(h) h ago"
            case .daysAgo(let d): return "\(d) d ago"
            case .inDuration(let d): return " (in \(d))"
            case .spendLabel: return "spend"
            case .fiveHourLimit: return "5-hour limit"
            case .sevenDayLimit: return "7-day limit"
            case .spendLimit: return "Spend limit"
            case .windowLimit(let label): return "\(label) limit"
            case .limitUsed(let title, let percent): return "\(title) \(percent) used"
            case .spendUsed(let title, let used, let limit, let percent): return "\(title) \(used) of \(limit) (\(percent))"
            case .spendPeriod(let period): return " \(period)"
            case .resets(let time): return " · resets \(time)"
            case .windowElapsed(let percent): return " · \(percent) of the window elapsed"
            case .context: return "Context"
            case .contextPercent(let percent): return "Context \(percent)"
            case .contextTokens(let used): return " · \(used) tokens"
            case .contextTokensOf(let used, let window): return " · \(used) of \(window) tokens"
            case .contextOver200k: return " · over 200k"
            case .cost(let cost): return "Cost \(cost)"
            case .costPerHour(let rate): return " · \(rate)/h"
            case .session(let duration): return "Session \(duration)"
            case .apiDuration(let duration): return " · API \(duration)"
            case .apiShare(let percent): return " (\(percent)% of wall time)"
            case .lines(let added, let removed): return "Lines +\(added) −\(removed)"
            case .promptCache(let percent): return "Prompt cache \(percent) hits"
            case .cacheWarm: return " · warm"
            case .cacheCold: return " · cold"
            case .tokens: return "Tokens"
            case .tokensIn(let count): return " \(count) in"
            case .tokensCached(let count): return " (\(count) cached)"
            case .tokensOut(let count): return " · \(count) out"
            case .tokensReasoning(let count): return " (\(count) reasoning)"
            case .updated(let age): return "Updated \(age)"
            case .idle: return " (idle)"
            }
        }
    }
}
