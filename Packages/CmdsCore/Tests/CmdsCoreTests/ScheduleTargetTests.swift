import XCTest
@testable import CmdsCore

final class ScheduleTargetTests: XCTestCase {
    private typealias C = ScheduleTarget.Candidate

    private let panes = [
        C(paneID: "p1", workspaceID: "w1", workspaceTitle: "API", tag: "t00000001"),
        C(paneID: "p2", workspaceID: "w2", workspaceTitle: "web", tag: "t00000002"),
        C(paneID: "p3", workspaceID: "w2", workspaceTitle: "web"),
        C(paneID: "p4", workspaceID: "w3", workspaceTitle: "Docs", isLocalTerminal: false),
        C(paneID: "p5", workspaceID: "w4", workspaceTitle: "ssh", tag: "t00000005", isLocalTerminal: false),
        C(paneID: "p6", workspaceID: "w5", workspaceTitle: "Twice"),
        C(paneID: "p7", workspaceID: "w6", workspaceTitle: "twice "),
    ]

    func testTag() {
        XCTAssertEqual(ScheduleTarget.resolve(.tag("t00000002"), in: panes), .pane("p2"))
        XCTAssertEqual(ScheduleTarget.resolve(.tag("t0000000f"), in: panes), .notFound)
        // A tag on a pane that cannot be typed into (SSH) is never used.
        XCTAssertEqual(ScheduleTarget.resolve(.tag("t00000005"), in: panes), .notFound)
        // Two panes with the same tag (should not happen): never guessed.
        let twice = panes + [C(paneID: "p9", workspaceID: "w9", workspaceTitle: "x", tag: "t00000001")]
        XCTAssertEqual(ScheduleTarget.resolve(.tag("t00000001"), in: twice), .ambiguous)
    }

    func testWorkspaceTitle() {
        // Trimmed and case-insensitive; exactly one workspace with exactly one local terminal pane.
        XCTAssertEqual(ScheduleTarget.resolve(.workspace(title: " api"), in: panes), .pane("p1"))
        XCTAssertEqual(ScheduleTarget.resolve(.workspace(title: "web"), in: panes), .ambiguous)
        XCTAssertEqual(ScheduleTarget.resolve(.workspace(title: "twice"), in: panes), .ambiguous)
        XCTAssertEqual(ScheduleTarget.resolve(.workspace(title: "Docs"), in: panes), .notFound)
        XCTAssertEqual(ScheduleTarget.resolve(.workspace(title: "nothing"), in: panes), .notFound)
        XCTAssertEqual(ScheduleTarget.Resolution.ambiguous.problem, .ambiguousTarget)
        XCTAssertEqual(ScheduleTarget.Resolution.notFound.problem, .paneNotFound)
        XCTAssertNil(ScheduleTarget.Resolution.pane("p1").problem)
    }

    func testPaneID() {
        XCTAssertEqual(ScheduleTarget.resolve(.pane("p3"), in: panes), .pane("p3"))
        XCTAssertEqual(ScheduleTarget.resolve(.pane("p4"), in: panes), .notFound)
    }

    func testRestoredTagsAreUnique() {
        // Invalid tags, tags already in use and repeats are dropped (an imported workspace, a hand-edited file).
        XCTAssertEqual(ScheduleTarget.uniqueTags(["t00000001", "t00000001", nil, "p3", "t00000002"], taken: ["t00000002"]),
                       ["t00000001", nil, nil, nil, nil])
    }

    // MARK: Notice

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
}
