import XCTest
@testable import CmdsCore

final class CronConversionTests: XCTestCase {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    /// 2026-11-04 10:00 in Tokyo; midnight is 10 h before.
    private let now = Date(timeIntervalSince1970: 1_793_754_000)
    private var midnight: Date { now.addingTimeInterval(-36000) }

    private func convert(_ cron: String) -> ScheduleTrigger? {
        try? CronConversion.trigger(cron, now: now, timeZone: tokyo).get()
    }

    private func why(_ cron: String) -> String? {
        if case .failure(let failure) = CronConversion.trigger(cron, now: now, timeZone: tokyo) { return failure.description }
        return nil
    }

    func testIntervals() {
        XCTAssertEqual(convert("*/5 * * * *"), .interval(every: 300, from: midnight))
        XCTAssertEqual(convert("3-58/5 * * * *"), .interval(every: 300, from: midnight.addingTimeInterval(180)))
        XCTAssertEqual(convert("7/15 * * * *"), .interval(every: 900, from: midnight.addingTimeInterval(420)))
        XCTAssertEqual(convert("0 * * * *"), .interval(every: 3600, from: midnight))
        XCTAssertEqual(convert("30 */2 * * *"), .interval(every: 7200, from: midnight.addingTimeInterval(1800)))
        XCTAssertEqual(convert("15 1/6 * * *"), .interval(every: 21600, from: midnight.addingTimeInterval(3600 + 900)))
    }

    func testWeekly() {
        XCTAssertEqual(convert("0 9 * * 1-5"), .weekly(WeeklyRule(weekdays: Weekday.workdays, times: [TimeOfDay("09:00")!])))
        XCTAssertEqual(convert("0,30 9,13 * * *"),
                       .weekly(WeeklyRule(weekdays: Set(Weekday.allCases), times: ["09:00", "09:30", "13:00", "13:30"].compactMap(TimeOfDay.init))))
        XCTAssertEqual(convert("0 8 * * sat,sun"), .weekly(WeeklyRule(weekdays: [.sat, .sun], times: [TimeOfDay("08:00")!])))
        XCTAssertEqual(convert("0 8 * * 0"), .weekly(WeeklyRule(weekdays: [.sun], times: [TimeOfDay("08:00")!])))
        XCTAssertEqual(convert("0 8 * * 7"), .weekly(WeeklyRule(weekdays: [.sun], times: [TimeOfDay("08:00")!])))
    }

    func testRefused() {
        XCTAssertEqual(why("* * * * *"), "more often than every 5 minutes")
        XCTAssertEqual(why("*/2 * * * *"), "more often than every 5 minutes")
        XCTAssertEqual(why("*/7 * * * *"), "every 7 minutes does not divide an hour")
        XCTAssertEqual(why("0 9 1 * *"), "day of month and month must be *")
        XCTAssertEqual(why("0 */5 * * *"), "every 5 hours does not divide a day")
        XCTAssertEqual(why("*/5 9-17 * * 1-5"), "minutes must be fixed (or */N with every hour)")
        XCTAssertEqual(why("0 9 * *"), "expected 5 fields")
        XCTAssertEqual(why("3-30/5 * * * *"), "minutes must be fixed (or */N with every hour)", "a range that stops early skips firings")
        XCTAssertEqual(why("0 9 * * funday"), "unknown day of week funday")
    }
}
