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
        XCTAssertEqual(settings.idleMinutes, 10)
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

    func testAgentWithNothingInProgressIsAStallAfterTheMinutes() {
        let idle = [StallNotice.Asking(pane: "p1", seconds: 9 * 60 + 59), .init(pane: "p2", seconds: 10 * 60),
                    .init(pane: "p3", seconds: 3 * 3600), .init(pane: "p9", seconds: 3600)]
        let stalls = StallNotice.stalls(asking: [], waiting: [], idle: idle, settings: on, toPane: "p9")
        XCTAssertEqual(stalls.map(\.pane), ["p3", "p2"])
        XCTAssertEqual(stalls.map(\.minutes), [180, 10])
        XCTAssertTrue(stalls.allSatisfy { $0.kind == .idle && $0.reason == .idle })
        XCTAssertEqual(StallNotice.line(stalls[1]), "cmds 詰まり通知: ペイン p2 / 待機中 / 10 分 / 理由 idle")
        // Its own minutes; 0 turns only this kind off.
        var settings = on
        settings.idleMinutes = 181
        XCTAssertEqual(StallNotice.stalls(asking: [], waiting: [], idle: idle, settings: settings, toPane: "p9"), [])
        settings.idleMinutes = 0
        XCTAssertEqual(StallNotice.stalls(asking: [], waiting: [], idle: idle, settings: settings, toPane: "p9"), [])
        let asking = [StallNotice.Asking(pane: "p4", seconds: 3600)]
        XCTAssertEqual(StallNotice.stalls(asking: asking, waiting: [], idle: idle, settings: settings, toPane: "p9").map(\.kind),
                       [.needsInput])
    }

    func testIdleAgentWithAnInstructionNotTypedInGetsOneLine() {
        let idle = [StallNotice.Asking(pane: "p1", seconds: 3600)]
        let typed = StallNotice.Waiting(pane: "p1", tag: "t1", seconds: 3600, hold: .typedInput)
        XCTAssertEqual(StallNotice.stalls(asking: [], waiting: [typed], idle: idle, settings: on, toPane: nil).map(\.kind),
                       [.undelivered])
        // An instruction that has not waited long enough yet does not hide the idle agent.
        let young = StallNotice.Waiting(pane: "p1", tag: "t1", seconds: 60, hold: .typedInput)
        XCTAssertEqual(StallNotice.stalls(asking: [], waiting: [young], idle: idle, settings: on, toPane: nil).map(\.kind), [.idle])
    }

    func testSettingsWithoutIdleMinutesTakeTheDefault() throws {
        let old = Data(#"{"enabled":true,"toTag":"t1","inputMinutes":5,"queueMinutes":20}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(StallNotice.Settings.self, from: old),
                       StallNotice.Settings(enabled: true, toTag: "t1", inputMinutes: 5, queueMinutes: 20, idleMinutes: 10))
        let odd = Data(#"{"enabled":true,"toTag":"t1","idleMinutes":-3}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(StallNotice.Settings.self, from: odd).idleMinutes, 10)
        let off = Data(#"{"enabled":true,"toTag":"t1","idleMinutes":0}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(StallNotice.Settings.self, from: off).idleMinutes, 0)
    }

    func testAStallIsToldOnceThenEveryHourAndAgainAfterItEnded() {
        let stall = StallNotice.Stall(pane: "p1", kind: .needsInput, minutes: 10, reason: .permissionOrQuestion, key: "p1:needsInput")
        var state = StallNotice.State()
        XCTAssertEqual(StallNotice.due([stall], state: &state, now: t0), [stall])
        // Not marked as sent (the line could not be kept): due again.
        XCTAssertEqual(StallNotice.due([stall], state: &state, now: t0 + 60), [stall])
        state.sent(stall, at: t0 + 60)
        XCTAssertEqual(StallNotice.due([stall], state: &state, now: t0 + 120), [])
        XCTAssertEqual(StallNotice.due([stall], state: &state, now: t0 + 60 + 3540), [])
        // The check an hour later, a moment early or late: told then, not a minute after.
        XCTAssertEqual(StallNotice.due([stall], state: &state, now: t0 + 60 + 3599.9), [stall])
        XCTAssertEqual(StallNotice.due([stall], state: &state, now: t0 + 60 + 3600), [stall])
        state.sent(stall, at: t0 + 3660)
        // Over, then stalled again: told at once.
        XCTAssertEqual(StallNotice.due([], state: &state, now: t0 + 3700), [])
        XCTAssertEqual(state.sentAt, [:])
        XCTAssertEqual(StallNotice.due([stall], state: &state, now: t0 + 3760), [stall])
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
