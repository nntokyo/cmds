import XCTest
@testable import cmds_cli
@testable import CmdsCore

/// The apps translate agent usage text (`AgentFormat.Strings`); the CLI and the socket API never do.
final class CLIFormatEnglishTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_250_000)

    private var usage: AgentUsage {
        var usage = AgentUsage(agent: .claude, model: "Opus", effort: "high", contextUsedPercent: 53.2)
        usage.contextTokens = 527_000
        usage.contextWindow = 1_000_000
        usage.costUSD = 117.99
        usage.sessionDurationMs = 12_300_000
        usage.apiDurationMs = 13_200_000
        usage.updatedAt = now.addingTimeInterval(-200)
        return usage
    }

    private var limits: [AgentLimits] {
        [AgentLimits(agent: .claude, limits: [UsageLimit(id: "spend", usedPercent: 24, usedUSD: 12, limitUSD: 50),
                                              UsageLimit(id: "five_hour", usedPercent: 40)],
                     updatedAt: now.addingTimeInterval(-700))]
    }

    func testAgentsAndLimitsStayEnglish() {
        // CmdsCore has no catalogs and the CLI passes no `strings:`, so this holds in any language.
        let list = AgentList(panes: [AgentPaneUsage(workspace: "w1", pane: "p1", usage: usage)], limits: limits)
        XCTAssertEqual(Format.agents(list, titles: ["w1": "cmds"], currentPane: "p1", now: now),
                       "> p1  cmds  Claude Opus (high)  ctx 53% 527k/1M │ $117.99 ($34.53/h) │ ⏱ 3h25m api 3h40m(107%)  (3 min ago)\n"
                       + "Claude  5h 40% · spend $12/$50  (as of 11 min ago)\n")
    }

    func testSharedFormattersDefaultToEnglish() {
        XCTAssertEqual(AgentFormat.detailLines(usage, now: now), [
            "Claude Opus (high)",
            "Context 53% · 527k of 1M tokens",
            "Cost $117.99 · $34.53/h",
            "Session 3h25m · API 3h40m (107% of wall time)",
            "Updated 3 min ago",
        ])
        XCTAssertEqual(AgentFormat.limitLines(limits[0].limits, now: now),
                       ["5-hour limit 40% used", "Spend limit $12.00 of $50.00 (24%)"])
        XCTAssertEqual(AgentFormat.limitsSummary(limits[0].limits), "5h 40% · spend $12/$50")
    }

    func testAppStringsOnlyApplyWhenPassed() {
        let japanese = AgentFormat.Strings(locale: Locale(identifier: "ja")) { text in
            switch text {
            case .fiveHourLimit: return "5時間の上限"
            case .limitUsed(let title, let percent): return "\(title)：\(percent)使用"
            case .spendLabel: return "利用額"
            case .durationHoursMinutes(let h, let m): return "\(h)時間\(m)分"
            case .inDuration(let d): return "（あと\(d)）"
            default: return text.english
            }
        }
        let windows = [UsageLimit(id: "five_hour", usedPercent: 40)]
        XCTAssertEqual(AgentFormat.limitLines(windows, now: now, strings: japanese), ["5時間の上限：40%使用"])
        XCTAssertEqual(AgentFormat.limitsSummary(limits[0].limits, strings: japanese), "5h 40% · 利用額 $12/$50")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(AgentFormat.resetTime(now.addingTimeInterval(7800), now: now, calendar: calendar, strings: japanese),
                       "07:10（あと2時間10分）")
        XCTAssertEqual(AgentFormat.resetTime(now.addingTimeInterval(3 * 86400), now: now, calendar: calendar, strings: japanese),
                       "日 05:00")
        // The default is untouched.
        XCTAssertEqual(AgentFormat.limitLines(windows, now: now), ["5-hour limit 40% used"])
    }
}
