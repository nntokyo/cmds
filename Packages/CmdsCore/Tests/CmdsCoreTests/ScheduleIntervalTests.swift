import XCTest
@testable import CmdsCore

/// `interval` triggers (#456).
final class ScheduleIntervalTests: XCTestCase {
    private let from = Date(timeIntervalSince1970: 1_793_700_000)

    func testNextFire() {
        let trigger = ScheduleTrigger.interval(every: 300, from: from)
        XCTAssertEqual(ScheduleCalendar.nextFire(trigger, after: from.addingTimeInterval(-10), accounts: []), from)
        XCTAssertEqual(ScheduleCalendar.nextFire(trigger, after: from, accounts: []), from.addingTimeInterval(300))
        XCTAssertEqual(ScheduleCalendar.nextFire(trigger, after: from.addingTimeInterval(299), accounts: []), from.addingTimeInterval(300))
        XCTAssertEqual(ScheduleCalendar.nextFire(trigger, after: from.addingTimeInterval(300), accounts: []), from.addingTimeInterval(600))
        XCTAssertEqual(ScheduleCalendar.nextFire(trigger, after: from.addingTimeInterval(86400 + 1), accounts: []),
                       from.addingTimeInterval(86400 + 300))
        XCTAssertNil(ScheduleCalendar.nextInterval(every: 0, from: from, after: from))
    }

    func testIntervalStart() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let now = Date(timeIntervalSince1970: 1_793_754_000 + 37) // 10:00:37 in Tokyo
        XCTAssertEqual(ScheduleCalendar.intervalStart(every: 300, now: now, timeZone: tokyo),
                       Date(timeIntervalSince1970: 1_793_754_000 - 36000))
        XCTAssertEqual(ScheduleCalendar.intervalStart(every: 420, now: now, timeZone: tokyo), Date(timeIntervalSince1970: 1_793_754_000))
    }

    func testCodableValidationAndVersion() throws {
        let draft = ScheduleDraft(name: "loop", trigger: .interval(every: 300, from: from),
                                  action: .sendText(SendText(target: .tag("t1a2b3c4d"), text: "check the queue", to: .agent)))
        XCTAssertEqual(draft.late, .untilNextRun, "a missed run runs once when the Mac is back")
        XCTAssertTrue(ScheduleValidation.problems(draft).isEmpty)
        var short = draft
        short.trigger = .interval(every: 60, from: from)
        XCTAssertEqual(ScheduleValidation.problems(short), [.intervalOutOfRange])
        short.trigger = .interval(every: 8 * 86400, from: from)
        XCTAssertEqual(ScheduleValidation.problems(short), [.intervalOutOfRange])

        let schedule = Schedule(id: "s00000001", draft: draft, origin: .app, createdAt: from)
        XCTAssertEqual(schedule.requiredVersion, 3)
        let file = ScheduleFile(schedules: [schedule])
        XCTAssertEqual(file.version, 3, "older builds open the file read only instead of dropping it")
        let data = try JSONEncoder().encode(file)
        let back = try JSONDecoder().decode(ScheduleFile.self, from: data)
        XCTAssertEqual(back.schedules, [schedule])
        XCTAssertEqual(back.dropped, 0)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let trigger = ((json?["schedules"] as? [[String: Any]])?.first?["trigger"]) as? [String: Any]
        XCTAssertEqual(trigger?["type"] as? String, "interval")
        XCTAssertEqual(trigger?["every"] as? Double, 300)
        XCTAssertFalse(schedule.trigger.isOneShot)
        XCTAssertTrue(schedule.trigger.hasFixedTimes)
    }

    func testNoNoticeUnderAnHour() {
        let action = ScheduleAction.sendText(SendText(target: .tag("t1a2b3c4d"), text: "x", to: .agent))
        var schedule = Schedule(id: "s00000001", draft: ScheduleDraft(name: "x", trigger: .interval(every: 300, from: from), action: action),
                                origin: .app, createdAt: from, nextFireAt: from.addingTimeInterval(300))
        XCTAssertNil(ScheduleNotice.time(of: schedule))
        schedule.trigger = .interval(every: 3600, from: from)
        XCTAssertNotNil(ScheduleNotice.time(of: schedule))
    }

    func testCatchUpTakesTheLatestPassedTime() {
        // Asleep for 3 hours past a 5-minute schedule: one run, for the latest time, as long as the next has not come.
        let trigger = ScheduleTrigger.interval(every: 300, from: from)
        let now = from.addingTimeInterval(3 * 3600 + 120)
        let (due, next) = ScheduleCatchUp.latestPassed(from.addingTimeInterval(300), now: now) {
            ScheduleCalendar.nextFire(trigger, after: $0, accounts: [])
        }
        XCTAssertEqual(due, from.addingTimeInterval(3 * 3600))
        XCTAssertEqual(next, from.addingTimeInterval(3 * 3600 + 300))
        XCTAssertEqual(ScheduleCatchUp.decide(nextFireAt: due, now: now, late: .untilNextRun, nextSlot: next), .run(.catchUp))
    }
}
