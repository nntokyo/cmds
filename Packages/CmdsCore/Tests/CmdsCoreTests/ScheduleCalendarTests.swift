import XCTest
@testable import CmdsCore

final class ScheduleCalendarTests: XCTestCase {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    private func times(_ texts: String...) -> [TimeOfDay] { texts.map { TimeOfDay($0)! } }

    private func weekly(_ days: Set<Weekday>, _ times: [TimeOfDay], zone: String? = nil) -> ScheduleTrigger {
        .weekly(WeeklyRule(weekdays: days, times: times, timeZone: zone))
    }

    // MARK: once

    func testOnceFiresWhileAhead() {
        let at = date("2026-11-04T02:00:00+09:00")
        XCTAssertEqual(ScheduleCalendar.nextFire(.once(at: at), after: date("2026-11-03T12:00:00+09:00"), accounts: []), at)
        XCTAssertNil(ScheduleCalendar.nextFire(.once(at: at), after: at, accounts: []))
        XCTAssertNil(ScheduleCalendar.nextFire(.once(at: at), after: at.addingTimeInterval(60), accounts: []))
    }

    // MARK: weekly

    func testWeekdaysSkipTheWeekend() {
        // Friday 2026-11-06 10:00 in Tokyo → Monday 09:00.
        let next = ScheduleCalendar.nextFire(weekly(Weekday.workdays, times("09:00"), zone: "Asia/Tokyo"),
                                             after: date("2026-11-06T10:00:00+09:00"), accounts: [])
        XCTAssertEqual(next, date("2026-11-09T09:00:00+09:00"))
    }

    func testSeveralTimesADay() {
        let trigger = weekly(Weekday.workdays, times("09:00", "13:30", "18:00"), zone: "Asia/Tokyo")
        XCTAssertEqual(ScheduleCalendar.nextFire(trigger, after: date("2026-11-04T10:00:00+09:00"), accounts: []),
                       date("2026-11-04T13:30:00+09:00"))
        XCTAssertEqual(ScheduleCalendar.nextFire(trigger, after: date("2026-11-04T13:30:00+09:00"), accounts: []),
                       date("2026-11-04T18:00:00+09:00"))
        XCTAssertEqual(ScheduleCalendar.nextFire(trigger, after: date("2026-11-04T18:00:00+09:00"), accounts: []),
                       date("2026-11-05T09:00:00+09:00"))
    }

    func testAcrossTheEndOfTheWeek() {
        // Saturdays only, from Sunday → the next Saturday; from Saturday after the time → a week later.
        let trigger = weekly([.sat], times("08:00"), zone: "Asia/Tokyo")
        XCTAssertEqual(ScheduleCalendar.nextFire(trigger, after: date("2026-11-08T12:00:00+09:00"), accounts: []),
                       date("2026-11-14T08:00:00+09:00"))
        XCTAssertEqual(ScheduleCalendar.nextFire(trigger, after: date("2026-11-14T08:00:00+09:00"), accounts: []),
                       date("2026-11-21T08:00:00+09:00"))
        // Sunday early in the morning after a Saturday-night time.
        let late = weekly([.sat], times("23:55"), zone: "Asia/Tokyo")
        XCTAssertEqual(ScheduleCalendar.nextFire(late, after: date("2026-11-14T23:00:00+09:00"), accounts: []),
                       date("2026-11-14T23:55:00+09:00"))
    }

    func testTokyoAndNewYork() {
        let after = date("2026-11-08T00:00:00Z")
        let inTokyo = ScheduleCalendar.nextFire(weekly([.mon], times("09:00"), zone: "Asia/Tokyo"), after: after, accounts: [])
        let inNewYork = ScheduleCalendar.nextFire(weekly([.mon], times("09:00"), zone: "America/New_York"), after: after, accounts: [])
        XCTAssertEqual(inTokyo, date("2026-11-09T00:00:00Z"))
        XCTAssertEqual(inNewYork, date("2026-11-09T14:00:00Z"))
    }

    func testNoZoneFollowsTheMacsZone() {
        let trigger = weekly([.mon], times("09:00"))
        let after = date("2026-11-08T00:00:00Z")
        XCTAssertEqual(ScheduleCalendar.nextFire(trigger, after: after, accounts: [], timeZone: tokyo), date("2026-11-09T00:00:00Z"))
        // The Mac moved to New York: the same rule now means 09:00 there.
        XCTAssertEqual(ScheduleCalendar.nextFire(trigger, after: after, accounts: [], timeZone: newYork), date("2026-11-09T14:00:00Z"))
        // An unknown zone id (validation refuses it) falls back to the Mac's zone.
        XCTAssertEqual(ScheduleCalendar.zone(of: WeeklyRule(weekdays: [.mon], times: times("09:00"), timeZone: "Mars/Base"),
                                             fallback: utc), utc)
    }

    func testSpringForwardGapRunsRightAfterIt() {
        // New York, Sunday 2026-03-08: 02:00 → 03:00. 02:30 does not exist; it runs at 03:00 EDT (07:00 UTC).
        let trigger = weekly([.sun], times("02:30"), zone: "America/New_York")
        XCTAssertEqual(ScheduleCalendar.nextFire(trigger, after: date("2026-03-07T12:00:00Z"), accounts: []),
                       date("2026-03-08T07:00:00Z"))
        // The week after is normal again (02:30 EDT).
        XCTAssertEqual(ScheduleCalendar.nextFire(trigger, after: date("2026-03-08T07:00:00Z"), accounts: []),
                       date("2026-03-15T06:30:00Z"))
    }

    func testFallBackRepeatRunsOnce() {
        // New York, Sunday 2026-11-01: 02:00 EDT → 01:00 EST. 01:30 happens twice; only the first counts.
        let trigger = weekly([.sun], times("01:30"), zone: "America/New_York")
        let first = ScheduleCalendar.nextFire(trigger, after: date("2026-10-31T12:00:00Z"), accounts: [])
        XCTAssertEqual(first, date("2026-11-01T05:30:00Z"))
        XCTAssertEqual(ScheduleCalendar.nextFire(trigger, after: first!, accounts: []), date("2026-11-08T06:30:00Z"))
        // Also when looking from inside the repeated hour.
        XCTAssertEqual(ScheduleCalendar.nextFire(trigger, after: date("2026-11-01T06:00:00Z"), accounts: []),
                       date("2026-11-08T06:30:00Z"))
    }

    func testLeapDay() {
        // 2028-02-29 is a Tuesday.
        let trigger = weekly([.tue], times("12:00"), zone: "UTC")
        XCTAssertEqual(ScheduleCalendar.nextFire(trigger, after: date("2028-02-28T00:00:00Z"), accounts: []),
                       date("2028-02-29T12:00:00Z"))
        XCTAssertEqual(ScheduleCalendar.nextFire(trigger, after: date("2028-02-29T12:00:00Z"), accounts: []),
                       date("2028-03-07T12:00:00Z"))
    }

    // MARK: limitReset

    func testLimitResetFollowsTheAccountsLimit() {
        let now = date("2026-11-04T11:40:00Z")
        let reset = date("2026-11-04T15:00:00Z")
        var account = ClaudeAccount(name: "work", configDir: "~/.claude-work",
                                    limit: ClaudeAccountLimit(kind: .usageLimit, resetsAt: reset, estimated: true, detectedAt: now))
        let trigger = ScheduleTrigger.limitReset(account: "Work", delay: 60)
        // An estimated reset, matched ignoring case.
        XCTAssertEqual(ScheduleCalendar.nextFire(trigger, after: now, accounts: [account]), reset.addingTimeInterval(60))
        // Extended (merged with a later reset): the time moves with it.
        let later = ClaudeAccountLimit(kind: .usageLimit, resetsAt: reset.addingTimeInterval(3600), detectedAt: now)
        account.limit = ClaudeAccounts.merge(account.limit, later, now: now)
        XCTAssertEqual(ScheduleCalendar.nextFire(trigger, after: now, accounts: [account]), reset.addingTimeInterval(3660))
        // Cleared: due now.
        account.limit = nil
        XCTAssertEqual(ScheduleCalendar.nextFire(trigger, after: now, accounts: [account]), now)
        // The account was removed.
        XCTAssertNil(ScheduleCalendar.nextFire(trigger, after: now, accounts: []))
    }

    func testRepeatingLimitResetFiresOncePerReset() {
        let created = date("2026-11-04T10:00:00Z")
        let reset = date("2026-11-04T15:00:00Z")
        var account = ClaudeAccount(name: "work", configDir: "~/.claude-work",
                                    limit: ClaudeAccountLimit(kind: .usageLimit, resetsAt: reset, detectedAt: created))
        let trigger = ScheduleTrigger.limitReset(account: "work", delay: 60, repeats: true)
        var schedule = Schedule(id: "s00000001", draft: ScheduleDraft(name: "again", trigger: trigger,
                                                                      action: .continueSession(ContinueSession(sessionID: "abc"))),
                                origin: .app, createdAt: created)
        XCTAssertEqual(ScheduleCalendar.recomputed(schedule, now: created, accounts: [account], codex: nil), reset.addingTimeInterval(60))
        // Fired (handled): the same reset never fires again, the schedule waits for the next limit.
        schedule.lastDueAt = reset.addingTimeInterval(60)
        schedule.nextFireAt = nil
        XCTAssertNil(ScheduleCalendar.recomputed(schedule, now: reset.addingTimeInterval(120), accounts: [account], codex: nil))
        // A cleared limit does not fire a repeating trigger.
        account.limit = nil
        XCTAssertNil(ScheduleCalendar.recomputed(schedule, now: reset.addingTimeInterval(120), accounts: [account], codex: nil))
        // The next limit: its reset.
        let next = date("2026-11-04T23:00:00Z")
        account.limit = ClaudeAccountLimit(kind: .usageLimit, resetsAt: next, detectedAt: next.addingTimeInterval(-3600))
        XCTAssertEqual(ScheduleCalendar.recomputed(schedule, now: next.addingTimeInterval(-3600), accounts: [account], codex: nil),
                       next.addingTimeInterval(60))
        // A pending firing is kept when the limit is cleared before it, and dropped with the account.
        schedule.nextFireAt = next.addingTimeInterval(60)
        account.limit = nil
        XCTAssertEqual(ScheduleCalendar.recomputed(schedule, now: next, accounts: [account], codex: nil), next.addingTimeInterval(60))
        XCTAssertNil(ScheduleCalendar.recomputed(schedule, now: next, accounts: [], codex: nil))
        // A reset that was over before the schedule existed is not run (a stale limit).
        let stale = Schedule(id: "s00000002", draft: schedule.draft, origin: .app, createdAt: next.addingTimeInterval(3600))
        account.limit = ClaudeAccountLimit(kind: .usageLimit, resetsAt: next, detectedAt: next.addingTimeInterval(-3600))
        XCTAssertNil(ScheduleCalendar.recomputed(stale, now: next.addingTimeInterval(3600), accounts: [account], codex: nil))
        // One-shot triggers keep the phase-1 rule (cleared: due now).
        var once = schedule
        once.trigger = .limitReset(account: "work", delay: 60)
        account.limit = nil
        XCTAssertEqual(ScheduleCalendar.recomputed(once, now: next, accounts: [account], codex: nil), next)
    }

    func testCodexLimitReset() {
        let now = date("2026-11-04T11:40:00Z")
        let fiveHour = date("2026-11-04T15:00:00Z")
        let sevenDay = date("2026-11-06T09:00:00Z")
        func limits(_ windows: [(Double, Date?)]) -> AgentLimits {
            AgentLimits(agent: .codex, limits: windows.enumerated().map { index, window in
                UsageLimit(id: index == 0 ? UsageLimit.fiveHour : UsageLimit.sevenDay, usedPercent: window.0, resetsAt: window.1)
            }, updatedAt: now)
        }
        // The latest reset among the windows used up.
        XCTAssertEqual(limits([(100, fiveHour), (40, sevenDay)]).exhaustedReset, fiveHour)
        XCTAssertEqual(limits([(100, fiveHour), (100, sevenDay)]).exhaustedReset, sevenDay)
        XCTAssertNil(limits([(99.5, fiveHour)]).exhaustedReset)
        XCTAssertNil(limits([(100, nil)]).exhaustedReset)

        let once = ScheduleTrigger.codexLimitReset(delay: 60)
        XCTAssertEqual(ScheduleCalendar.nextFire(once, after: now, accounts: [], codex: limits([(100, fiveHour)])),
                       fiveHour.addingTimeInterval(60))
        // Usable again: due now. Not known: nil (and `recomputed` keeps the stored time).
        XCTAssertEqual(ScheduleCalendar.nextFire(once, after: now, accounts: [], codex: limits([(3, fiveHour)])), now)
        XCTAssertNil(ScheduleCalendar.nextFire(once, after: now, accounts: [], codex: nil))
        var schedule = Schedule(id: "s00000001", draft: ScheduleDraft(name: "codex", trigger: once,
                                                                      action: .continueSession(ContinueSession(agent: .codex, sessionID: "abc"))),
                                origin: .app, createdAt: now, nextFireAt: fiveHour.addingTimeInterval(60))
        XCTAssertEqual(ScheduleCalendar.recomputed(schedule, now: now, accounts: [], codex: nil), fiveHour.addingTimeInterval(60))
        // Repeating: a later reset after the last handled one.
        schedule.trigger = .codexLimitReset(delay: 60, repeats: true)
        schedule.lastDueAt = fiveHour.addingTimeInterval(60)
        schedule.nextFireAt = nil
        XCTAssertNil(ScheduleCalendar.recomputed(schedule, now: fiveHour, accounts: [], codex: limits([(100, fiveHour)])))
        XCTAssertNil(ScheduleCalendar.recomputed(schedule, now: fiveHour, accounts: [], codex: limits([(2, sevenDay)])))
        XCTAssertEqual(ScheduleCalendar.recomputed(schedule, now: fiveHour, accounts: [], codex: limits([(100, sevenDay)])),
                       sevenDay.addingTimeInterval(60))
        // New figures after the reset (no window used up) never drop a pending firing.
        schedule.nextFireAt = sevenDay.addingTimeInterval(60)
        XCTAssertEqual(ScheduleCalendar.recomputed(schedule, now: sevenDay, accounts: [], codex: limits([(1, nil)])),
                       sevenDay.addingTimeInterval(60))
        // Weekly and once triggers are not recomputed from limits.
        schedule.trigger = .once(at: sevenDay)
        XCTAssertEqual(ScheduleCalendar.recomputed(schedule, now: now, accounts: [], codex: nil), schedule.nextFireAt)
    }

    // MARK: catch-up

    func testCatchUp() {
        let due = date("2026-11-04T09:00:00Z")
        let sixHours = ScheduleLatePolicy.runIfWithin(6 * 3600)
        XCTAssertEqual(ScheduleCatchUp.decide(nextFireAt: nil, now: due, late: sixHours), .notDue)
        XCTAssertEqual(ScheduleCatchUp.decide(nextFireAt: due, now: due.addingTimeInterval(-1), late: sixHours), .notDue)
        XCTAssertEqual(ScheduleCatchUp.decide(nextFireAt: due, now: due, late: sixHours), .run(.scheduled))
        // The safety check may be up to a minute late: still on time, also with skip.
        XCTAssertEqual(ScheduleCatchUp.decide(nextFireAt: due, now: due.addingTimeInterval(61), late: .skip), .run(.scheduled))
        XCTAssertEqual(ScheduleCatchUp.decide(nextFireAt: due, now: due.addingTimeInterval(2 * 3600), late: sixHours), .run(.catchUp))
        XCTAssertEqual(ScheduleCatchUp.decide(nextFireAt: due, now: due.addingTimeInterval(6 * 3600), late: sixHours), .run(.catchUp))
        XCTAssertEqual(ScheduleCatchUp.decide(nextFireAt: due, now: due.addingTimeInterval(6 * 3600 + 1), late: sixHours), .missed)
        XCTAssertEqual(ScheduleCatchUp.decide(nextFireAt: due, now: due.addingTimeInterval(600), late: .skip), .missed)
        // Weekly default: 15 minutes.
        let weeklyDefault = ScheduleLatePolicy.defaultPolicy(for: weekly([.mon], times("09:00")))
        XCTAssertEqual(weeklyDefault, .runIfWithin(900))
        XCTAssertEqual(ScheduleCatchUp.decide(nextFireAt: due, now: due.addingTimeInterval(14 * 60), late: weeklyDefault), .run(.catchUp))
        XCTAssertEqual(ScheduleCatchUp.decide(nextFireAt: due, now: due.addingTimeInterval(16 * 60), late: weeklyDefault), .missed)
        XCTAssertEqual(ScheduleLatePolicy.defaultPolicy(for: .once(at: due)), .runIfWithin(6 * 3600))
        XCTAssertEqual(ScheduleLatePolicy.defaultPolicy(for: .limitReset(account: "a", delay: 60)), .runIfWithin(6 * 3600))
    }

    // MARK: times of day

    func testTimeOfDayParsing() {
        XCTAssertEqual(TimeOfDay("9:05")?.text, "09:05")
        XCTAssertEqual(TimeOfDay("23:59")?.minutes, 23 * 60 + 59)
        for bad in ["24:00", "9", "9:5", "09:60", "-1:00", "a:bc", "09:00:00", "١٢:٠٠", ""] {
            XCTAssertNil(TimeOfDay(bad), bad)
        }
    }
}
