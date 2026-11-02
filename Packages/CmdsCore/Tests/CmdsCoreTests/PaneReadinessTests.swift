import XCTest
@testable import CmdsCore

/// The one readiness check for typing into panes (#47): the rules resuming, account switching and schedule runs
/// used before they were shared, unchanged.
final class PaneReadinessTests: XCTestCase {
    private typealias R = PaneReadiness

    private func prompt(settled: TimeInterval) -> PaneObservation {
        PaneObservation(foreground: .shell, screenUnchangedFor: settled, atEmptyPrompt: true)
    }

    // MARK: Constants

    func testTimesAreUnchanged() {
        XCTAssertEqual(R.localStartDelay, 0.8)
        XCTAssertEqual(R.sshStartDelay, 1.5)
        XCTAssertEqual(R.promptSettleTime, 0.4)
        XCTAssertEqual(R.unreportedPromptSettleTime, 1.5)
        XCTAssertEqual(R.agentIdleTime, 2)
        XCTAssertEqual(ScheduleRunTiming.shellSettleTime, R.promptSettleTime)
    }

    // MARK: Empty prompt

    func testEmptyPromptNeedsTextOnScreen() {
        XCTAssertTrue(R.isAtEmptyPrompt(screen: "~ % ", cursor: (0, 4)))
        XCTAssertFalse(R.isAtEmptyPrompt(screen: "~ % git", cursor: (0, 7)))
        XCTAssertFalse(R.isAtEmptyPrompt(screen: "  \n \n", cursor: (0, 0)))
        XCTAssertFalse(R.isAtEmptyPrompt(screen: "", cursor: (0, 0)))
        XCTAssertTrue(R.isBlank(" \n\t"))
        XCTAssertFalse(R.isBlank(" % "))
    }

    // MARK: Shell and agent

    func testShellReadyOnlyAtASettledEmptyPrompt() {
        XCTAssertTrue(R.isShellReady(prompt(settled: 0.4)))
        XCTAssertFalse(R.isShellReady(prompt(settled: 0.39)))
        var o = prompt(settled: 5)
        o.atEmptyPrompt = false
        XCTAssertFalse(R.isShellReady(o))
        for foreground in [PaneForeground.unknown, .agent, .other] {
            o = prompt(settled: 5)
            o.foreground = foreground
            XCTAssertFalse(R.isShellReady(o), "\(foreground)")
        }
    }

    func testAgentIdleIsTheAccountSwitchRule() {
        let activities: [AgentActivity] = [.none, .idle, .busy, .needsInput]
        for foreground in [PaneForeground.unknown, .shell, .agent, .other] {
            for activity in activities {
                for subagent in [false, true] {
                    for unchanged in [0, 1.9, 2, 60] as [TimeInterval] {
                        let o = PaneObservation(foreground: foreground, activity: activity, subagentRunning: subagent,
                                                screenUnchangedFor: unchanged)
                        let old = ClaudeAccountSwitchTiming.isIdle(agentInForeground: foreground == .agent,
                                                                   busy: activity == .busy, subagentRunning: subagent,
                                                                   screenUnchangedFor: unchanged)
                        XCTAssertEqual(R.isAgentIdle(o), old)
                    }
                }
            }
        }
        XCTAssertTrue(R.isAgentIdle(PaneObservation(foreground: .agent, activity: .idle, screenUnchangedFor: 2)))
        // needsInput is not busy: the account switch's Ctrl-C still goes in (a schedule run checks it separately).
        XCTAssertTrue(R.isAgentIdle(PaneObservation(foreground: .agent, activity: .needsInput, screenUnchangedFor: 2)))
    }

    // MARK: Resume

    func testResumeNeverTypesOverAnAgent() {
        // A reported agent wins over everything else, local or SSH.
        XCTAssertEqual(R.resumeGate(foreground: .shell, agentReported: true, remote: nil), .agentRunning)
        XCTAssertEqual(R.resumeGate(foreground: .unknown, agentReported: true,
                                    remote: .init(connected: true, sinceStart: 10, promptReported: true)), .agentRunning)
        XCTAssertEqual(R.resumeGate(foreground: .agent, agentReported: false, remote: nil), .agentRunning)
    }

    func testResumeLocalWaitsForTheShell() {
        XCTAssertNil(R.resumeGate(foreground: .shell, agentReported: false, remote: nil))
        XCTAssertEqual(R.resumeGate(foreground: .other, agentReported: false, remote: nil), .wait)
        XCTAssertEqual(R.resumeGate(foreground: .unknown, agentReported: false, remote: nil), .wait)
        XCTAssertEqual(R.resumeStep(prompt(settled: 0.4), remote: nil), .ready)
        XCTAssertEqual(R.resumeStep(prompt(settled: 0.39), remote: nil), .wait)
        XCTAssertEqual(R.resumeStep(prompt(settled: 0), remote: nil), .wait) // the screen just changed
        var o = prompt(settled: 10)
        o.atEmptyPrompt = false
        XCTAssertEqual(R.resumeStep(o, remote: nil), .wait)
    }

    func testResumeSSHWaitsForTheConnectionAndAPrompt() {
        func remote(_ connected: Bool, _ since: TimeInterval, _ reported: Bool) -> R.Remote {
            R.Remote(connected: connected, sinceStart: since, promptReported: reported)
        }
        // The foreground process of an SSH pane is not read.
        XCTAssertNil(R.resumeGate(foreground: .unknown, agentReported: false, remote: remote(true, 1.5, false)))
        XCTAssertEqual(R.resumeGate(foreground: .unknown, agentReported: false, remote: remote(true, 1.4, true)), .wait)
        XCTAssertEqual(R.resumeGate(foreground: .unknown, agentReported: false, remote: remote(false, 60, true)), .wait)
        let ssh = PaneObservation(screenUnchangedFor: 0.4, atEmptyPrompt: true)
        XCTAssertEqual(R.resumeStep(ssh, remote: remote(true, 5, true)), .ready)
        XCTAssertEqual(R.resumeStep(ssh, remote: remote(true, 5, false)), .wait)
        var settled = ssh
        settled.screenUnchangedFor = 1.5
        XCTAssertEqual(R.resumeStep(settled, remote: remote(true, 5, false)), .ready)
        settled.atEmptyPrompt = false
        XCTAssertEqual(R.resumeStep(settled, remote: remote(true, 5, true)), .wait)
    }

    // MARK: Screen

    func testScreenStabilityCountsFromTheLastChange() {
        var s = ScreenStability()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(s.update("a", at: t0), 0)
        XCTAssertEqual(s.update("a", at: t0.addingTimeInterval(1)), 1)
        XCTAssertEqual(s.update("b", at: t0.addingTimeInterval(2)), 0)
        XCTAssertEqual(s.update("b", at: t0.addingTimeInterval(2.5)), 0.5)
        s.reset()
        XCTAssertNil(s.screen)
        XCTAssertNil(s.since)
        XCTAssertEqual(s.update("b", at: t0.addingTimeInterval(3)), 0) // the same text counts as new after a reset
        XCTAssertEqual(s.since, t0.addingTimeInterval(3))
    }

    func testWorkingLineOnlyAtTheBottom() {
        let working = """
            › fix the login test

            • Working (12s • esc to interrupt)

            ▌ Ask Codex to do anything
            """
        XCTAssertTrue(PaneReadiness.showsWorking(screen: working))
        XCTAssertTrue(PaneReadiness.showsWorking(screen: "✻ Thinking… (esc to interrupt)\n> \n"))
        XCTAssertFalse(PaneReadiness.showsWorking(screen: "› done\n\n▌ Ask Codex to do anything\n"))
        // Old output higher up that quotes the words does not count.
        let quoted = "press esc to interrupt it\n" + (1...10).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertFalse(PaneReadiness.showsWorking(screen: quoted))
    }

    func testCodexIdleIsStricterThanClaude() {
        var o = PaneObservation(foreground: .agent, agentOnTerminal: true, activity: .idle, screenUnchangedFor: 2)
        XCTAssertTrue(PaneReadiness.isAgentIdle(o))
        XCTAssertFalse(PaneReadiness.isCodexIdle(o, sessionReported: true))
        o.screenUnchangedFor = PaneReadiness.codexIdleTime
        XCTAssertTrue(PaneReadiness.isCodexIdle(o, sessionReported: true))
        XCTAssertFalse(PaneReadiness.isCodexIdle(o, sessionReported: false))
        o.activity = .busy
        XCTAssertFalse(PaneReadiness.isCodexIdle(o, sessionReported: true))
        o.activity = .idle
        o.foreground = .shell
        XCTAssertFalse(PaneReadiness.isCodexIdle(o, sessionReported: true))
    }
}
