import XCTest
@testable import cmds_cli
@testable import CmdsCore

/// `cmds schedule from-session` (#458).
final class SessionJobsCLITests: XCTestCase {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let now = Date(timeIntervalSince1970: 1_793_754_000)

    private var found: SessionJobs {
        SessionJobs(pane: "p3", sessionID: "s", jobs: [
            .init(id: "89b1ef41", cron: "3-58/5 * * * *", prompt: "Run PROCESS.md"),
            .init(id: "7c7c7c7c", cron: "0 9 1 * *", prompt: "Monthly"),
            .init(id: "5e5e5e5e", cron: "*/10 * * * *", prompt: "Queue"),
        ])
    }

    func testPlan() throws {
        let send = SendText(target: .tag("t1a2b3c4d"), text: "Queue", to: .agent)
        let moved = Schedule(id: "s00000001", draft: ScheduleDraft(name: "Queue", trigger: .interval(every: 600, from: now),
                                                                   action: .sendText(send)), origin: .app, createdAt: now)
        let list = ScheduleList(schedules: [ScheduleListEntry(schedule: moved, targetPane: "p3")])
        let plan = SessionJobPlan.make(found, existing: list, now: now, timeZone: tokyo)
        XCTAssertEqual(plan.map(\.state), [.toAdd, .unsupported("day of month and month must be *"), .moved("s00000001")])
        let text = Format.sessionJobPlan(found, plan, applied: false, timeZone: tokyo)
        XCTAssertTrue(text.contains("89b1ef41  3-58/5 * * * *  → every 5m  (with --apply)"), text)
        XCTAssertTrue(text.contains("CronDelete 5e5e5e5e"), "a moved job still has to be stopped in the session")
        // Another pane's schedule with the same prompt is not this job.
        let other = ScheduleList(schedules: [ScheduleListEntry(schedule: moved, targetPane: "p9")])
        XCTAssertEqual(SessionJobPlan.make(found, existing: other, now: now, timeZone: tokyo)[2].state, .toAdd)
    }

    func testNames() {
        XCTAssertEqual(SessionJobPlan.name(for: "Run PROCESS.md\nthen report"), "Run PROCESS.md")
        XCTAssertEqual(SessionJobPlan.name(for: String(repeating: "a", count: 60)).count, 48)
        XCTAssertEqual(SessionJobPlan.name(for: "  \n"), "Session job")
    }

    func testEmpty() {
        XCTAssertEqual(Format.sessionJobPlan(SessionJobs(pane: "p3", sessionID: "s", jobs: []), [], applied: false),
                       "no recurring CronCreate jobs in the session of p3\n")
    }
}
