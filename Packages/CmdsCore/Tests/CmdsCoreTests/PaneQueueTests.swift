import XCTest
@testable import CmdsCore

/// Instructions kept for a busy pane (`PaneQueue`, `PaneQueueTiming`).
final class PaneQueueTests: XCTestCase {
    private typealias T = PaneQueueTiming
    private let now = Date(timeIntervalSince1970: 1_795_600_000)

    /// Claude Code idle at its prompt.
    private func idle() -> ScheduleRunTiming.Observation {
        var o = ScheduleRunTiming.Observation()
        o.foreground = .agent
        o.agentOnTerminal = true
        o.activity = .idle
        o.screenUnchangedFor = 3
        o.agent = .claude
        o.agentReported = true
        return o
    }

    // MARK: The queue

    func testOldestFirstPerPane() throws {
        var queue = PaneQueue()
        let a = try queue.add(text: "first", paneTag: "t0000000a", now: now)
        let b = try queue.add(text: "other pane", paneTag: "t0000000b", now: now)
        let c = try queue.add(text: "second", paneTag: "t0000000a", now: now)
        XCTAssertEqual(queue.head(of: "t0000000a"), a)
        XCTAssertEqual(queue.head(of: "t0000000b"), b)
        XCTAssertEqual(queue.position(of: c.id), 2)
        XCTAssertEqual(queue.paneTags, ["t0000000a", "t0000000b"])
        XCTAssertEqual(Set([a.id, b.id, c.id]).count, 3)
        XCTAssertTrue(a.id.hasPrefix("q"))

        XCTAssertEqual(queue.end(id: a.id, .delivered, now: now.addingTimeInterval(60)), a)
        XCTAssertEqual(queue.head(of: "t0000000a"), c)
        XCTAssertEqual(queue.position(of: c.id), 1)
        XCTAssertNil(queue.position(of: a.id))
        XCTAssertEqual(queue.recent.first?.outcome, .delivered)
        XCTAssertNil(queue.end(id: a.id, .cancelled, now: now), "an instruction ends once")
    }

    func testRefusesWhatCannotBeTyped() {
        var queue = PaneQueue()
        XCTAssertThrowsError(try queue.add(text: "  \n", paneTag: "t0000000a", now: now)) { XCTAssertEqual($0 as? PaneQueue.Problem, .emptyText) }
        XCTAssertThrowsError(try queue.add(text: "a\u{1B}[2Jb", paneTag: "t0000000a", now: now)) {
            XCTAssertEqual($0 as? PaneQueue.Problem, .controlCharacters)
        }
        XCTAssertThrowsError(try queue.add(text: String(repeating: "x", count: ScheduleLimits.maxPromptBytes + 1),
                                           paneTag: "t0000000a", now: now)) { XCTAssertEqual($0 as? PaneQueue.Problem, .textTooLong) }
        XCTAssertNil(PaneQueue.problem(of: "line one\nline two\tend"))
        XCTAssertTrue(queue.items.isEmpty)
    }

    func testLimits() throws {
        var queue = PaneQueue()
        for index in 0..<PaneQueue.maxPerPane { try queue.add(text: "n\(index)", paneTag: "t0000000a", now: now) }
        XCTAssertThrowsError(try queue.add(text: "one more", paneTag: "t0000000a", now: now)) {
            XCTAssertEqual($0 as? PaneQueue.Problem, .paneFull)
        }
        XCTAssertNoThrow(try queue.add(text: "another pane", paneTag: "t0000000b", now: now))
    }

    func testRecentIsTrimmedAndHoldsNoText() throws {
        var queue = PaneQueue()
        for index in 0..<(PaneQueue.maxRecent + 5) {
            let item = try queue.add(text: "secret \(index)", paneTag: "t0000000a", now: now)
            queue.end(id: item.id, .delivered, now: now)
        }
        XCTAssertEqual(queue.recent.count, PaneQueue.maxRecent)
        let data = try JSONEncoder().encode(queue.recent)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret"))
    }

    func testSurvivesARestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pane-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = PaneQueue.url(supportDirectory: directory)
        guard case .missing = PaneQueue.load(from: url) else { return XCTFail("a file before the first save") }

        var queue = PaneQueue()
        try queue.add(text: "after the build, run the tests\nand report", paneTag: "t0000000a", from: "p12", now: now)
        let done = try queue.add(text: "done", paneTag: "t0000000a", now: now)
        queue.end(id: done.id, .unconfirmed, now: now.addingTimeInterval(5))
        try queue.save(to: url)

        guard case .loaded(let loaded) = PaneQueue.load(from: url) else { return XCTFail("the saved queue does not load") }
        XCTAssertEqual(loaded, queue)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600, "instructions are readable by the user only")
    }

    // MARK: When it is typed

    func testPastesIntoAnIdleAgent() {
        XCTAssertEqual(T.step(phase: .waiting, observation: idle(), elapsed: 0), .paste)
        var codex = idle()
        codex.agent = .codex
        codex.screenUnchangedFor = PaneReadiness.codexIdleTime
        XCTAssertEqual(T.step(phase: .waiting, observation: codex, elapsed: 0), .paste)
    }

    func testHoldsWhileTheAgentWorks() {
        var busy = idle()
        busy.activity = .busy
        XCTAssertEqual(T.step(phase: .waiting, observation: busy, elapsed: 0), .hold(.busy))
        var working = idle()
        working.workingOnScreen = true
        XCTAssertEqual(T.step(phase: .waiting, observation: working, elapsed: 0), .hold(.busy))
        var subagent = idle()
        subagent.subagentRunning = true
        XCTAssertEqual(T.step(phase: .waiting, observation: subagent, elapsed: 0), .hold(.busy))
        var unsettled = idle()
        unsettled.screenUnchangedFor = 0.1
        XCTAssertEqual(T.step(phase: .waiting, observation: unsettled, elapsed: 0), .hold(.busy))
    }

    /// Unlike a schedule run, which fails after `idleWait`, an instruction waits as long as the agent works.
    func testNeverGivesUpOnABusyAgent() {
        var busy = idle()
        busy.activity = .busy
        let day: TimeInterval = 24 * 3600
        XCTAssertEqual(ScheduleRunTiming.step(state: .waitingForAgent, observation: busy, elapsed: day), .fail(.agentBusy))
        XCTAssertEqual(T.step(phase: .waiting, observation: busy, elapsed: day), .hold(.busy))
        XCTAssertEqual(T.step(phase: .waiting, observation: idle(), elapsed: day), .paste)
    }

    func testHoldsWhileAPersonHasTypedText() {
        var typed = idle()
        typed.inputHasText = true
        XCTAssertEqual(T.step(phase: .waiting, observation: typed, elapsed: 0), .hold(.typedInput))
        // A schedule run keeps to the same rule.
        XCTAssertEqual(ScheduleRunTiming.step(state: .waitingForAgent, observation: typed, elapsed: 0), .wait)
        typed.inputHasText = false
        XCTAssertEqual(T.step(phase: .waiting, observation: typed, elapsed: 0), .paste)
    }

    func testHoldsOnQuestionsAndChoices() {
        var asking = idle()
        asking.activity = .needsInput
        XCTAssertEqual(T.step(phase: .waiting, observation: asking, elapsed: 0), .hold(.needsInput))
        var choice = idle()
        choice.choiceOnScreen = true
        XCTAssertEqual(T.step(phase: .waiting, observation: choice, elapsed: 0), .hold(.needsInput))
    }

    /// A dialog instead of the input box (the folder trust question): nothing is typed, by a schedule run either.
    func testHoldsWhileADialogIsShown() {
        var dialog = idle()
        dialog.inputBoxMissing = true
        XCTAssertEqual(T.step(phase: .waiting, observation: dialog, elapsed: 0), .hold(.needsInput))
        XCTAssertEqual(ScheduleRunTiming.step(state: .waitingForAgent, observation: dialog, elapsed: 0), .wait)
    }

    func testHoldsWhenNoAgentCanTakeIt() {
        var shell = ScheduleRunTiming.Observation()
        shell.foreground = .shell
        shell.atEmptyPrompt = true
        XCTAssertEqual(T.step(phase: .waiting, observation: shell, elapsed: 0), .hold(.agentNotRunning), "never typed into a shell")
        var other = ScheduleRunTiming.Observation()
        other.foreground = .other
        XCTAssertEqual(T.step(phase: .waiting, observation: other, elapsed: 0), .hold(.otherProgram))
        var unknownAgent = idle()
        unknownAgent.agent = nil
        XCTAssertEqual(T.step(phase: .waiting, observation: unknownAgent, elapsed: 0), .hold(.otherProgram))
        var gone = ScheduleRunTiming.Observation()
        gone.paneExists = false
        XCTAssertEqual(T.step(phase: .waiting, observation: gone, elapsed: 0), .hold(.paneNotFound))
    }

    func testHoldsWhileSomethingElseTypes() {
        var run = idle()
        run.otherInputInProgress = true
        XCTAssertEqual(T.step(phase: .waiting, observation: run, elapsed: 0), .hold(.otherInput))
        // And a schedule run waits for an instruction being typed.
        XCTAssertEqual(ScheduleRunTiming.step(state: .waitingForAgent, observation: run, elapsed: 0), .wait)
        var switching = idle()
        switching.accountSwitchInProgress = true
        XCTAssertEqual(T.step(phase: .waiting, observation: switching, elapsed: 0), .hold(.otherInput))
        var resume = idle()
        resume.resumeQueued = true
        XCTAssertEqual(T.step(phase: .waiting, observation: resume, elapsed: 0), .hold(.otherInput))
    }

    func testReturnFollowsThePaste() {
        XCTAssertEqual(T.step(phase: .typing, observation: idle(), elapsed: 0.1), .wait)
        XCTAssertEqual(T.step(phase: .typing, observation: idle(), elapsed: ScheduleRunTiming.enterDelay), .enter)
        var left = idle()
        left.foreground = .shell
        XCTAssertEqual(T.step(phase: .typing, observation: left, elapsed: 1), .end(.failed), "Return goes only to the agent that got the paste")
    }

    func testEndsWhenTheAgentStarts() {
        XCTAssertEqual(T.step(phase: .confirming, observation: idle(), elapsed: 1), .wait)
        var started = idle()
        started.promptSubmitted = true
        XCTAssertEqual(T.step(phase: .confirming, observation: started, elapsed: 1), .end(.delivered))
        XCTAssertEqual(T.step(phase: .confirming, observation: idle(), elapsed: ScheduleRunTiming.confirmTimeout), .end(.unconfirmed))
    }

    func testListRoundTrips() throws {
        let list = PaneQueueList(waiting: [.init(id: "q0000000a", pane: "p3", workspaceTitle: "sales", text: "report",
                                                 createdAt: "2026-11-25T07:00:00Z", position: 1, hold: .typedInput)],
                                 recent: [.init(id: "q0000000b", pane: nil, outcome: .delivered, endedAt: "2026-11-25T06:59:00Z")])
        let json = try JSONValue.from(list)
        guard case .array(let waiting)? = json["waiting"] else { return XCTFail("waiting is not an array") }
        XCTAssertEqual(waiting.first?["hold"]?.stringValue, "typedInput")
        XCTAssertEqual(try json.decode(PaneQueueList.self), list)
    }
}
