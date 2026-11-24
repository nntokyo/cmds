import Foundation
import XCTest
@testable import CmdsCore

/// Late policy "until the next time" (#45 phase 5).
final class ScheduleLateUntilNextTests: XCTestCase {
    private let nine = Date(timeIntervalSince1970: 1_800_000_000)
    private var tomorrow: Date { nine.addingTimeInterval(86400) }

    func testRunsOnceUntilTheNextSlot() {
        let decide = { (now: Date) in ScheduleCatchUp.decide(nextFireAt: self.nine, now: now, late: .untilNextRun, nextSlot: self.tomorrow) }
        XCTAssertEqual(decide(nine.addingTimeInterval(30)), .run(.scheduled))
        XCTAssertEqual(decide(nine.addingTimeInterval(75 * 60)), .run(.catchUp), "woke at 10:15: the report runs")
        XCTAssertEqual(decide(tomorrow.addingTimeInterval(-60)), .run(.catchUp))
        XCTAssertEqual(decide(tomorrow.addingTimeInterval(60)), .missed, "the next day's time came: never two runs")
        XCTAssertEqual(ScheduleCatchUp.decide(nextFireAt: nine, now: nine.addingTimeInterval(75 * 60), late: .runIfWithin(15 * 60)),
                       .missed, "the weekly default stays as it was")
    }

    func testAfterDaysAsleepTheLatestTimeIsCaughtUp() {
        let daily = { (date: Date) -> Date? in date.addingTimeInterval(86400) }
        let woke = nine.addingTimeInterval(2 * 86400 + 75 * 60)  // two days later, 10:15
        let latest = ScheduleCatchUp.latestPassed(nine, now: woke, next: daily)
        XCTAssertEqual(latest.due, nine.addingTimeInterval(2 * 86400), "today's 09:00")
        XCTAssertEqual(latest.next, nine.addingTimeInterval(3 * 86400))
        XCTAssertEqual(ScheduleCatchUp.decide(nextFireAt: latest.due, now: woke, late: .untilNextRun, nextSlot: latest.next),
                       .run(.catchUp), "one run for today, none for the days before")
        XCTAssertEqual(ScheduleCatchUp.latestPassed(nine, now: nine.addingTimeInterval(60), next: daily).due, nine)
    }

    func testWithoutALaterSlotItIsTheLongestWindow() {
        XCTAssertEqual(ScheduleCatchUp.decide(nextFireAt: nine, now: nine.addingTimeInterval(86400), late: .untilNextRun), .run(.catchUp))
        XCTAssertEqual(ScheduleCatchUp.decide(nextFireAt: nine, now: nine.addingTimeInterval(ScheduleLimits.maxLateWindow + 1),
                                              late: .untilNextRun), .missed)
    }

    func testStoredSoOlderVersionsReadIt() throws {
        let data = try JSONEncoder().encode(ScheduleLatePolicy.untilNextRun)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "runIfWithin", "an older cmds reads the longest window")
        XCTAssertEqual(json["seconds"] as? Double, ScheduleLimits.maxLateWindow)
        XCTAssertEqual(try JSONDecoder().decode(ScheduleLatePolicy.self, from: data), .untilNextRun)
        let old = try JSONDecoder().decode(ScheduleLatePolicy.self, from: Data(#"{"type":"runIfWithin","seconds":900}"#.utf8))
        XCTAssertEqual(old, .runIfWithin(900))
    }
}

/// Why a time was missed (#45 phase 5).
final class ScheduleMissedReasonTests: XCTestCase {
    func testReasons() {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ScheduleCatchUp.missedReason(due: due, launchedAt: due.addingTimeInterval(600), lastWakeAt: nil), .cmdsNotRunning)
        XCTAssertEqual(ScheduleCatchUp.missedReason(due: due, launchedAt: due.addingTimeInterval(600),
                                                    lastWakeAt: due.addingTimeInterval(700)), .cmdsNotRunning, "started after it")
        XCTAssertEqual(ScheduleCatchUp.missedReason(due: due, launchedAt: due.addingTimeInterval(-86400),
                                                    lastWakeAt: due.addingTimeInterval(4500)), .macAsleep)
        XCTAssertEqual(ScheduleCatchUp.missedReason(due: due, launchedAt: due.addingTimeInterval(-86400),
                                                    lastWakeAt: due.addingTimeInterval(-60)), .missed, "neither seen after it")
    }

    func testOlderReadersSeeAReason() throws {
        let data = try JSONEncoder().encode([ScheduleReason.macAsleep, .cmdsNotRunning])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["macAsleep","cmdsNotRunning"]"#)
        let newer = #"{"id":"r1","scheduleID":"s1","scheduleName":"x","cause":"scheduled","dueAt":1794441600,"startedAt":1794441600,"state":"missed","reason":"somethingNewer"}"#
        XCTAssertEqual(try JSONDecoder().decode(ScheduleRun.self, from: Data(newer.utf8)).reason, .other,
                       "a run record from a newer cmds still reads")
    }
}
