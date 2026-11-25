import XCTest
@testable import CmdsCore

/// Panes with nothing in progress for N minutes (`IdlePanes`, `cmds idle`).
final class IdlePanesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_600_000)
    private var start: Date { now.addingTimeInterval(-6 * 3600) }

    private func pane(_ id: String, _ activity: AgentActivity = .idle, workedMinutesAgo: Double? = nil,
                      subagent: Bool = false, input: Bool = false, queued: Int = 0) -> IdlePanes.Candidate {
        IdlePanes.Candidate(pane: id, workspace: "w1", workspaceTitle: "sales", agent: .claude, activity: activity,
                            subagentRunning: subagent, inputInProgress: input,
                            lastWorkAt: workedMinutesAgo.map { now.addingTimeInterval(-$0 * 60) }, watchedSince: start,
                            queued: queued)
    }

    func testListsPanesIdleForTheThreshold() {
        let report = IdlePanes.report([pane("p1", workedMinutesAgo: 45), pane("p2", workedMinutesAgo: 29.9),
                                       pane("p3", workedMinutesAgo: 30)], minutes: 30, now: now)
        XCTAssertEqual(report.minutes, 30)
        XCTAssertEqual(report.panes.map(\.pane), ["p1", "p3"], "longest first; 29.9 minutes is not 30")
        XCTAssertEqual(report.panes[0].idleSeconds, 45 * 60)
        XCTAssertEqual(report.panes[0].since, ISO8601DateFormatter().string(from: now.addingTimeInterval(-45 * 60)))
        XCTAssertEqual(report.panes[0].agent, "claude")
        XCTAssertEqual(report.panes[0].state, "idle")
        XCTAssertFalse(report.panes[0].sinceIsWatchStart)
    }

    func testDefaultIsThirtyMinutes() {
        XCTAssertEqual(IdlePanes.defaultMinutes, 30)
        XCTAssertTrue(IdlePanes.minutesRange.contains(1))
        XCTAssertFalse(IdlePanes.minutesRange.contains(0))
    }

    func testWorkInProgressIsNotIdle() {
        let candidates = [pane("busy", .busy, workedMinutesAgo: 90), pane("subagent", workedMinutesAgo: 90, subagent: true),
                          pane("typing", workedMinutesAgo: 90, input: true), pane("none", .none, workedMinutesAgo: 90)]
        XCTAssertTrue(IdlePanes.report(candidates, minutes: 30, now: now).panes.isEmpty)
    }

    func testAnAgentWaitingForAnAnswerIsListed() {
        let report = IdlePanes.report([pane("p1", .needsInput, workedMinutesAgo: 40)], minutes: 30, now: now)
        XCTAssertEqual(report.panes.map(\.state), ["needsInput"])
    }

    /// An agent cmds never saw working counts from when cmds started watching, and says so.
    func testNeverSeenWorkingCountsFromTheWatchStart() {
        let report = IdlePanes.report([pane("p1")], minutes: 30, now: now)
        XCTAssertEqual(report.panes.first?.idleSeconds, 6 * 3600)
        XCTAssertEqual(report.panes.first?.sinceIsWatchStart, true)
        let justStarted = IdlePanes.Candidate(pane: "p2", workspace: "w1", workspaceTitle: "sales", agent: .codex,
                                              activity: .idle, watchedSince: now.addingTimeInterval(-60))
        XCTAssertTrue(IdlePanes.report([justStarted], minutes: 30, now: now).panes.isEmpty)
    }

    func testQueuedInstructionsAreShown() {
        let report = IdlePanes.report([pane("p1", workedMinutesAgo: 40, queued: 2)], minutes: 30, now: now)
        XCTAssertEqual(report.panes.first?.queued, 2, "idle with instructions waiting: something holds them")
    }

    func testReportRoundTrips() throws {
        let report = IdlePanes.report([pane("p1", workedMinutesAgo: 45)], minutes: 5, now: now)
        let json = try JSONValue.from(report)
        guard case .array(let panes)? = json["panes"] else { return XCTFail("panes is not an array") }
        XCTAssertEqual(panes.first?["idleSeconds"]?.intValue, 2700)
        XCTAssertEqual(try json.decode(IdlePaneReport.self), report)
    }
}
