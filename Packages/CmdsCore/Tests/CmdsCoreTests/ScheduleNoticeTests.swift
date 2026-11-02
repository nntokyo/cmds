import XCTest
@testable import CmdsCore

final class ScheduleNoticeTests: XCTestCase {
    private func schedule(next: Date?, warn: Bool = true, enabled: Bool = true) -> Schedule {
        Schedule(id: "s00000001", draft: ScheduleDraft(name: "x", enabled: enabled, trigger: .once(at: Date(timeIntervalSince1970: 0)),
                                                      action: .startWorkspace(StartWorkspace(cwd: "/tmp")), warn: warn),
                 origin: .app, createdAt: Date(timeIntervalSince1970: 0), nextFireAt: next)
    }

    func testNoticeAMinuteBefore() {
        let fire = Date(timeIntervalSince1970: 10_000)
        let s = schedule(next: fire)
        XCTAssertEqual(ScheduleNotice.time(of: s), fire.addingTimeInterval(-60))
        XCTAssertFalse(ScheduleNotice.isDue(s, now: fire.addingTimeInterval(-61), shownFor: nil))
        XCTAssertTrue(ScheduleNotice.isDue(s, now: fire.addingTimeInterval(-60), shownFor: nil))
        XCTAssertTrue(ScheduleNotice.isDue(s, now: fire.addingTimeInterval(-5), shownFor: nil))
        // Once per firing time; a moved firing gets its own.
        XCTAssertFalse(ScheduleNotice.isDue(s, now: fire.addingTimeInterval(-5), shownFor: fire))
        XCTAssertTrue(ScheduleNotice.isDue(s, now: fire.addingTimeInterval(-5), shownFor: fire.addingTimeInterval(-3600)))
        // None once it is due (a late run is a catch-up), when off, or without warn.
        XCTAssertFalse(ScheduleNotice.isDue(s, now: fire, shownFor: nil))
        XCTAssertFalse(ScheduleNotice.isDue(schedule(next: fire, warn: false), now: fire.addingTimeInterval(-5), shownFor: nil))
        XCTAssertFalse(ScheduleNotice.isDue(schedule(next: fire, enabled: false), now: fire.addingTimeInterval(-5), shownFor: nil))
        XCTAssertNil(ScheduleNotice.time(of: schedule(next: nil)))
    }

    func testNextNoticeTime() {
        let fire = Date(timeIntervalSince1970: 10_000)
        let now = fire.addingTimeInterval(-600)
        func s(_ id: String, _ next: Date?, warn: Bool = true) -> Schedule {
            var made = schedule(next: next, warn: warn)
            made.id = id
            return made
        }
        let schedules = [s("s00000001", fire), s("s00000002", fire.addingTimeInterval(-300)),
                         s("s00000003", fire.addingTimeInterval(-400), warn: false), s("s00000004", nil)]
        // The earliest notice still ahead.
        XCTAssertEqual(ScheduleNotice.nextTime(of: schedules, after: now, shownFor: [:]), fire.addingTimeInterval(-360))
        // One already shown for its firing time does not count; one shown for an earlier time does.
        XCTAssertEqual(ScheduleNotice.nextTime(of: schedules, after: now, shownFor: ["s00000002": fire.addingTimeInterval(-300)]),
                       fire.addingTimeInterval(-60))
        XCTAssertEqual(ScheduleNotice.nextTime(of: schedules, after: now, shownFor: ["s00000002": fire]),
                       fire.addingTimeInterval(-360))
        // A notice time that has come is not ahead.
        XCTAssertEqual(ScheduleNotice.nextTime(of: schedules, after: fire.addingTimeInterval(-360), shownFor: [:]),
                       fire.addingTimeInterval(-60))
        XCTAssertNil(ScheduleNotice.nextTime(of: schedules, after: fire, shownFor: [:]))
    }
}
