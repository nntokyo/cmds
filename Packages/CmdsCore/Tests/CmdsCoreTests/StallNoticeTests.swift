import XCTest
@testable import CmdsCore

final class StallNoticeTests: XCTestCase {
    private let on = StallNotice.Settings(enabled: true, toTag: "t-told", inputMinutes: 10, queueMinutes: 15)
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testOffAndUnsetByDefault() {
        let settings = StallNotice.Settings()
        XCTAssertFalse(settings.enabled)
        XCTAssertNil(settings.toTag)
        XCTAssertEqual(settings.inputMinutes, 10)
        XCTAssertEqual(settings.queueMinutes, 15)
    }

    func testAgentAskingForInputIsAStallOnlyAfterTheMinutes() {
        let asking = [StallNotice.Asking(pane: "p1", seconds: 9 * 60 + 59), .init(pane: "p2", seconds: 10 * 60),
                      .init(pane: "p3", seconds: 4 * 3600 + 30)]
        let stalls = StallNotice.stalls(asking: asking, waiting: [], settings: on, toPane: "p9")
        XCTAssertEqual(stalls.map(\.pane), ["p3", "p2"])
        XCTAssertEqual(stalls.map(\.minutes), [240, 10])
        XCTAssertTrue(stalls.allSatisfy { $0.kind == .needsInput && $0.reason == .permissionOrQuestion })
    }

    func testKeptInstructionNotTypedInIsAStallWithItsReason() {
        let waiting = [StallNotice.Waiting(pane: "p1", tag: "t1", seconds: 14 * 60, hold: .typedInput),
                       .init(pane: "p2", tag: "t2", seconds: 15 * 60, hold: .typedInput),
                       .init(pane: "p3", tag: "t3", seconds: 16 * 60, hold: .busy),
                       .init(pane: nil, tag: "t4", seconds: 17 * 60, hold: .paneNotFound),
                       .init(pane: "p5", tag: "t5", seconds: 18 * 60, hold: nil)]
        let stalls = StallNotice.stalls(asking: [], waiting: waiting, settings: on, toPane: "p9")
        XCTAssertEqual(stalls.map(\.pane), ["p5", nil, "p3", "p2"])
        XCTAssertEqual(stalls.map(\.reason), [.unknown, .paneClosed, .busy, .typedInput])
        XCTAssertTrue(stalls.allSatisfy { $0.kind == .undelivered })
        XCTAssertEqual(Set(stalls.map(\.key)).count, 4)
    }

    func testEveryHoldHasAReasonWord() {
        let holds: [PaneQueueHold] = [.busy, .needsInput, .typedInput, .agentNotRunning, .otherProgram, .otherInput, .paneNotFound]
        XCTAssertEqual(holds.map { StallNotice.Reason(hold: $0).rawValue },
                       ["busy", "needs-input", "typed-input", "no-agent", "other-program", "other-input", "pane-closed"])
    }

    func testThePaneThatIsToldIsNeverReported() {
        let asking = [StallNotice.Asking(pane: "p9", seconds: 3600)]
        let waiting = [StallNotice.Waiting(pane: "p9", tag: "t-told", seconds: 3600, hold: .busy, from: "p1"),
                       // Not open: known by its tag only.
                       .init(pane: nil, tag: "t-told", seconds: 3600, hold: .paneNotFound)]
        XCTAssertEqual(StallNotice.stalls(asking: asking, waiting: waiting, settings: on, toPane: "p9"), [])
        XCTAssertEqual(StallNotice.stalls(asking: [], waiting: [waiting[1]], settings: on, toPane: nil), [])
    }

    func testLinesOfCmdsItselfAreNeverReported() {
        let waiting = [StallNotice.Waiting(pane: "p2", tag: "t2", seconds: 3600, hold: .busy, from: StallNotice.queueSource)]
        XCTAssertEqual(StallNotice.stalls(asking: [], waiting: waiting, settings: on, toPane: "p9"), [])
    }

    func testOneLinePerPaneWhenItsInstructionWaitsForTheSameQuestion() {
        let asking = [StallNotice.Asking(pane: "p1", seconds: 1200)]
        let held = StallNotice.Waiting(pane: "p1", tag: "t1", seconds: 1200, hold: .needsInput)
        XCTAssertEqual(StallNotice.stalls(asking: asking, waiting: [held], settings: on, toPane: nil).map(\.kind), [.needsInput])
        // A different reason is a second stall; so is a question that is not long enough yet.
        let typed = StallNotice.Waiting(pane: "p1", tag: "t1", seconds: 1200, hold: .typedInput)
        XCTAssertEqual(StallNotice.stalls(asking: asking, waiting: [typed], settings: on, toPane: nil).count, 2)
        let young = [StallNotice.Asking(pane: "p1", seconds: 60)]
        XCTAssertEqual(StallNotice.stalls(asking: young, waiting: [held], settings: on, toPane: nil).map(\.kind), [.undelivered])
    }

    func testAStallIsToldOnceThenEveryHourAndAgainAfterItEnded() {
        let stall = StallNotice.Stall(pane: "p1", kind: .needsInput, minutes: 10, reason: .permissionOrQuestion, key: "p1:needsInput")
        var state = StallNotice.State()
        XCTAssertEqual(StallNotice.due([stall], state: &state, now: t0), [stall])
        // Not marked as sent (the line could not be kept): due again.
        XCTAssertEqual(StallNotice.due([stall], state: &state, now: t0 + 60), [stall])
        state.sent(stall, at: t0 + 60)
        XCTAssertEqual(StallNotice.due([stall], state: &state, now: t0 + 120), [])
        XCTAssertEqual(StallNotice.due([stall], state: &state, now: t0 + 60 + 3599), [])
        XCTAssertEqual(StallNotice.due([stall], state: &state, now: t0 + 60 + 3600), [stall])
        state.sent(stall, at: t0 + 3660)
        // Over, then stalled again: told at once.
        XCTAssertEqual(StallNotice.due([], state: &state, now: t0 + 3700), [])
        XCTAssertEqual(state.sentAt, [:])
        XCTAssertEqual(StallNotice.due([stall], state: &state, now: t0 + 3760), [stall])
    }

    func testNoSecondLineWhileTheFirstStillWaits() {
        var state = StallNotice.State()
        let stall = StallNotice.stalls(asking: [.init(pane: "p1", seconds: 600)], waiting: [], settings: on, toPane: "p9")
        XCTAssertEqual(StallNotice.stale(stall, state: &state, waiting: []), [])
        XCTAssertEqual(StallNotice.toKeep(StallNotice.due(stall, state: &state, now: t0), state: &state, now: t0), stall)
        state.sent(stall[0], at: t0, line: "q1")
        // An hour on the pane that is told has not read it: no second line, and the hour counts from now.
        let hour = t0.addingTimeInterval(3600)
        XCTAssertEqual(StallNotice.stale(stall, state: &state, waiting: ["q1"]), [])
        XCTAssertEqual(StallNotice.toKeep(StallNotice.due(stall, state: &state, now: hour), state: &state, now: hour), [])
        XCTAssertEqual(StallNotice.due(stall, state: &state, now: hour.addingTimeInterval(1800)), [])
        // Typed in since: the next hour's line is kept.
        let later = hour.addingTimeInterval(3600)
        XCTAssertEqual(StallNotice.stale(stall, state: &state, waiting: []), [])
        XCTAssertEqual(StallNotice.toKeep(StallNotice.due(stall, state: &state, now: later), state: &state, now: later), stall)
    }

    func testAWaitingLineIsTakenBackWhenItsStallIsOver() {
        var state = StallNotice.State()
        let stalls = StallNotice.stalls(asking: [.init(pane: "p1", seconds: 600), .init(pane: "p2", seconds: 600)], waiting: [],
                                        settings: on, toPane: "p9")
        state.sent(stalls[0], at: t0, line: "q1")
        state.sent(stalls[1], at: t0, line: "q2")
        // p1 was answered while both lines wait; an instruction of someone else (q7) is never touched.
        let left = stalls.filter { $0.pane == "p2" }
        XCTAssertEqual(StallNotice.stale(left, state: &state, waiting: ["q1", "q2", "q7"]), ["q1"])
        XCTAssertEqual(state.lines, [left[0].key: "q2"])
        // A line that was typed in is not taken back.
        XCTAssertEqual(StallNotice.stale([], state: &state, waiting: ["q7"]), [])
        XCTAssertEqual(state.lines, [:])
    }

    func testTheLinesLeaveRoomInTheQueueOfThePaneThatIsTold() {
        XCTAssertLessThan(StallNotice.maxWaitingLines, PaneQueue.maxPerPane)
        var state = StallNotice.State()
        let asking = (1...14).map { StallNotice.Asking(pane: "p\($0)", seconds: 600 + $0) }
        let stalls = StallNotice.stalls(asking: asking, waiting: [], settings: on, toPane: "p99")
        let first = StallNotice.toKeep(StallNotice.due(stalls, state: &state, now: t0), state: &state, now: t0)
        XCTAssertEqual(first.count, StallNotice.maxWaitingLines)
        for (index, stall) in first.enumerated() { state.sent(stall, at: t0, line: "q\(index)") }
        // All still wait: nothing more is kept, and the other four stay due.
        let minute = t0.addingTimeInterval(60)
        let waiting = Set(state.lines.values)
        XCTAssertEqual(StallNotice.stale(stalls, state: &state, waiting: waiting), [])
        let due = StallNotice.due(stalls, state: &state, now: minute)
        XCTAssertEqual(due.count, 4)
        XCTAssertEqual(StallNotice.toKeep(due, state: &state, now: minute), [])
        // Three were typed in: three more are kept.
        let read = Set(waiting.sorted().dropFirst(3))
        XCTAssertEqual(StallNotice.stale(stalls, state: &state, waiting: read), [])
        XCTAssertEqual(StallNotice.toKeep(StallNotice.due(stalls, state: &state, now: minute), state: &state, now: minute).count, 3)
    }

    func testTurningOnOrOffOrTellingAnotherPaneStartsOver() {
        var other = on
        other.inputMinutes = 30
        XCTAssertFalse(StallNotice.startsOver(from: on, to: other))
        other.toTag = "t-other"
        XCTAssertTrue(StallNotice.startsOver(from: on, to: other))
        var off = on
        off.enabled = false
        XCTAssertTrue(StallNotice.startsOver(from: on, to: off))
        XCTAssertTrue(StallNotice.startsOver(from: off, to: on))
    }

    func testTheLineHasTheFixedFormAndNothingElse() {
        let asking = StallNotice.Stall(pane: "p12", kind: .needsInput, minutes: 240, reason: .permissionOrQuestion, key: "k")
        XCTAssertEqual(StallNotice.line(asking), "cmds 詰まり通知: ペイン p12 / 入力待ち / 240 分 / 理由 permission-or-question")
        let closed = StallNotice.Stall(pane: nil, kind: .undelivered, minutes: 15, reason: .paneClosed, key: "k")
        XCTAssertEqual(StallNotice.line(closed), "cmds 詰まり通知: ペイン - / 預けた指示が未達 / 15 分 / 理由 pane-closed")
        // Every line is one line that the queue accepts, whatever the reason.
        for reason in StallNotice.Reason.allCases {
            let line = StallNotice.line(.init(pane: "p1", kind: .undelivered, minutes: 1440, reason: reason, key: "k"))
            XCTAssertFalse(line.contains("\n"))
            XCTAssertNil(PaneQueue.problem(of: line))
        }
    }

    func testListTextHasTheTimeTheCountAndTheSameLines() {
        let asking = StallNotice.Stall(pane: "p12", kind: .needsInput, minutes: 240, reason: .permissionOrQuestion, key: "a")
        let closed = StallNotice.Stall(pane: nil, kind: .undelivered, minutes: 15, reason: .paneClosed, key: "b")
        XCTAssertEqual(StallNotice.listText([asking, closed], now: t0),
                       "cmds stall 2027-01-15T08:00:00Z 2\n\(StallNotice.line(asking))\n\(StallNotice.line(closed))\n")
        // No stall: still written, so a reader knows the file is fresh.
        XCTAssertEqual(StallNotice.listText([], now: t0), "cmds stall 2027-01-15T08:00:00Z 0\n")
    }

    func testListFileIsReplacedAndPrivate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stall-list-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = StallNotice.listURL(supportDirectory: dir)
        XCTAssertEqual(url.lastPathComponent, "stalls.txt")
        let stall = StallNotice.Stall(pane: "p1", kind: .undelivered, minutes: 20, reason: .typedInput, key: "k")
        try StallNotice.writeList([stall], now: t0, to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count, 2)
        try StallNotice.writeList([], now: t0 + 60, to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "cmds stall 2027-01-15T08:01:00Z 0\n")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testSettingsFileRoundTripAndLenientReading() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stall-notice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = StallNotice.url(supportDirectory: dir)
        XCTAssertEqual(StallNotice.loadSettings(from: url), StallNotice.Settings())
        try StallNotice.save(on, to: url)
        XCTAssertEqual(StallNotice.loadSettings(from: url), on)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        try Data(#"{"enabled":true,"toTag":"","inputMinutes":0,"queueMinutes":"x"}"#.utf8).write(to: url)
        XCTAssertEqual(StallNotice.loadSettings(from: url), StallNotice.Settings(enabled: true))
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(StallNotice.loadSettings(from: url), StallNotice.Settings())
    }
}
