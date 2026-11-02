import XCTest
@testable import CmdsCore

final class ScheduleRunTimingTests: XCTestCase {
    private typealias T = ScheduleRunTiming

    /// A shell sitting at an empty, settled prompt.
    private var shell: T.Observation {
        var o = T.Observation()
        o.foreground = .shell
        o.atEmptyPrompt = true
        o.screenUnchangedFor = 1
        return o
    }

    /// Claude Code idle at its prompt, reporting `session`.
    private func agent(_ session: String? = "abc") -> T.Observation {
        var o = T.Observation()
        o.foreground = .agent
        o.agentOnTerminal = true
        o.activity = .idle
        o.screenUnchangedFor = 3
        o.agent = .claude
        o.agentReported = session != nil
        o.sessionID = session
        return o
    }

    private let owned = T.Expectation(startsAgent: true, ownsPane: true)
    private let session = T.Expectation(sessionID: "abc")

    /// Codex idle at its prompt: its session file matched, quiet, screen unchanged for 5 s.
    private func codex() -> T.Observation {
        var o = T.Observation()
        o.foreground = .agent
        o.agentOnTerminal = true
        o.activity = .idle
        o.screenUnchangedFor = PaneReadiness.codexIdleTime
        o.agent = .codex
        o.agentReported = true
        o.sessionID = "019a"
        return o
    }

    /// `sendText` to an agent: Claude Code or Codex, the user's pane.
    private let anyAgent = T.Expectation(agent: nil, startsAgent: false, ownsPane: false)

    // MARK: Codex (phase 2)

    func testCodexIdleNeedsEveryCondition() {
        let codexSession = T.Expectation(agent: .codex, sessionID: "019a")
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: codex(), elapsed: 1, expect: codexSession), .paste)
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: codex(), elapsed: 1, expect: anyAgent), .paste)
        let blockers: [(String, (inout T.Observation) -> Void)] = [
            ("session file not matched", { $0.agentReported = false }),
            ("writing to its session file", { $0.activity = .busy }),
            ("screen changed within 5 s", { $0.screenUnchangedFor = 4.9 }),
            ("working line on screen", { $0.workingOnScreen = true }),
            ("a choice on screen", { $0.choiceOnScreen = true }),
            ("asks for input", { $0.activity = .needsInput }),
            ("resume queued", { $0.resumeQueued = true }),
            ("not in the foreground", { $0.foreground = .unknown }),
        ]
        for (name, block) in blockers {
            var o = codex()
            block(&o)
            let step = T.step(state: .waitingForAgent, observation: o, elapsed: 1, expect: anyAgent)
            XCTAssertNotEqual(step, .paste, name)
            XCTAssertFalse([T.Step.type, .enter].contains(step), name)
        }
        // Busy for 30 minutes: the run fails, nothing is typed.
        var busy = codex()
        busy.workingOnScreen = true
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: busy, elapsed: T.idleWait, expect: anyAgent), .fail(.agentBusy))
        // Claude Code's rules stay as they were (2 s), plus the working line.
        var claude = agent()
        claude.screenUnchangedFor = 2
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: claude, elapsed: 1, expect: session), .paste)
        claude.workingOnScreen = true
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: claude, elapsed: 1, expect: session), .wait)
    }

    func testOnlyTheExpectedAgent() {
        let codexSession = T.Expectation(agent: .codex, sessionID: "019a")
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: agent(), elapsed: 1, expect: codexSession), .skip(.notCodex))
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: codex(), elapsed: 1, expect: session), .skip(.notClaude))
        var other = codex()
        other.sessionID = "019b"
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: other, elapsed: 1, expect: codexSession), .skip(.differentSession))
        // An agent of unknown kind is never typed into.
        var unknown = agent()
        unknown.agent = nil
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: unknown, elapsed: 1, expect: anyAgent), .wait)
    }

    func testSendTextToTheUsersPane() {
        // To an agent: a shell or another program in the pane skips the run.
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: shell, elapsed: 1, expect: anyAgent), .skip(.agentNotRunning))
        var program = shell
        program.foreground = .other
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: program, elapsed: 1, expect: anyAgent), .skip(.otherProgram))
        // To a shell: only at an empty prompt; an agent or a program (e.g. `sleep 60`) skips it.
        let shellText = T.Expectation(agent: nil, startsAgent: false, ownsPane: false)
        XCTAssertEqual(T.step(state: .waitingForPane, observation: shell, elapsed: 1, expect: shellText), .type)
        XCTAssertEqual(T.step(state: .waitingForPane, observation: codex(), elapsed: 1, expect: shellText), .skip(.agentRunning))
        XCTAssertEqual(T.step(state: .waitingForPane, observation: program, elapsed: 1, expect: shellText), .wait)
        XCTAssertEqual(T.step(state: .waitingForPane, observation: program, elapsed: T.otherProgramGrace, expect: shellText),
                       .skip(.otherProgram))
        var backgrounded = shell
        backgrounded.agentOnTerminal = true
        XCTAssertEqual(T.step(state: .waitingForPane, observation: backgrounded, elapsed: 1, expect: shellText), .skip(.agentRunning))
    }

    // MARK: waitingForAccount

    func testAccountWait() {
        var o = T.Observation()
        XCTAssertEqual(T.step(state: .waitingForAccount, observation: o, elapsed: 0), .proceed)
        o.accountLimited = true
        o.accountFreeIn = 3600
        XCTAssertEqual(T.step(state: .waitingForAccount, observation: o, elapsed: 0), .wait)
        // The reset is beyond the 8 h wait (counted from when the run started waiting).
        o.accountFreeIn = 2 * 3600
        XCTAssertEqual(T.step(state: .waitingForAccount, observation: o, elapsed: 7 * 3600), .fail(.accountStillLimited))
        o.accountFreeIn = nil
        XCTAssertEqual(T.step(state: .waitingForAccount, observation: o, elapsed: 0), .fail(.accountStillLimited))
        XCTAssertEqual(T.autoAccountFreeIn(resets: [Date(timeIntervalSince1970: 7200), Date(timeIntervalSince1970: 3600)],
                                           now: Date(timeIntervalSince1970: 0)), 3600)
        XCTAssertNil(T.autoAccountFreeIn(resets: [Date(timeIntervalSince1970: 9 * 3600)], now: Date(timeIntervalSince1970: 0)))
        XCTAssertNil(T.autoAccountFreeIn(resets: [], now: Date()))
    }

    // MARK: waitingForPane (shell)

    func testShellReadyTypesOnce() {
        XCTAssertEqual(T.step(state: .waitingForPane, observation: shell, elapsed: 1, expect: owned), .type)
        var o = shell
        o.screenUnchangedFor = 0.1
        XCTAssertEqual(T.step(state: .waitingForPane, observation: o, elapsed: 1, expect: owned), .wait)
        o = shell
        o.atEmptyPrompt = false // something typed after the prompt, or a password question
        XCTAssertEqual(T.step(state: .waitingForPane, observation: o, elapsed: 1, expect: owned), .wait)
        XCTAssertEqual(T.step(state: .waitingForPane, observation: o, elapsed: 60, expect: owned), .fail(.shellNotReady))
        XCTAssertEqual(T.step(state: .waitingForPane, observation: o, elapsed: 60, expect: session), .skip(.otherProgram))
    }

    func testShellWaitsForAQueuedResumeOrSwitch() {
        var o = shell
        o.resumeQueued = true
        XCTAssertEqual(T.step(state: .waitingForPane, observation: o, elapsed: 1, expect: owned), .wait)
        o = shell
        o.accountSwitchInProgress = true
        XCTAssertEqual(T.step(state: .waitingForPane, observation: o, elapsed: 1, expect: owned), .wait)
    }

    func testNeverTypesIntoAnAgentOrAnotherProgram() {
        var o = shell
        o.agentOnTerminal = true // backgrounded Claude Code
        XCTAssertEqual(T.step(state: .waitingForPane, observation: o, elapsed: 1, expect: owned), .skip(.agentRunning))
        XCTAssertEqual(T.step(state: .waitingForPane, observation: agent(), elapsed: 1, expect: session), .skip(.agentRunning))
        // `sleep 60` in the user's pane: left alone after a short grace.
        o = T.Observation()
        o.foreground = .other
        XCTAssertEqual(T.step(state: .waitingForPane, observation: o, elapsed: 1, expect: session), .wait)
        XCTAssertEqual(T.step(state: .waitingForPane, observation: o, elapsed: 3, expect: session), .skip(.otherProgram))
        // In the run's own pane (a slow shell startup) it waits up to the timeout.
        XCTAssertEqual(T.step(state: .waitingForPane, observation: o, elapsed: 30, expect: owned), .wait)
        XCTAssertEqual(T.step(state: .waitingForPane, observation: o, elapsed: 60, expect: owned), .fail(.shellNotReady))
        // Not known yet.
        XCTAssertEqual(T.step(state: .waitingForPane, observation: T.Observation(), elapsed: 1, expect: owned), .wait)
        XCTAssertEqual(T.step(state: .waitingForPane, observation: T.Observation(), elapsed: 61, expect: owned), .fail(.shellNotReady))
    }

    func testPaneClosed() {
        var o = shell
        o.paneExists = false
        for state in [ScheduleRunState.waitingForPane, .waitingForAgent, .typing] {
            XCTAssertEqual(T.step(state: state, observation: o, elapsed: 1, expect: owned), .fail(.paneClosed), "\(state)")
        }
    }

    // MARK: waitingForAgent

    func testPastesIntoIdleClaudeCode() {
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: agent(), elapsed: 1, expect: session), .paste)
        // Any Claude Code the run started, whatever its session.
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: agent(nil), elapsed: 1, expect: owned), .paste)
    }

    func testNeverPastesIntoABusyAgent() {
        var o = agent()
        o.activity = .busy
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: o, elapsed: 1, expect: session), .wait)
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: o, elapsed: 30 * 60, expect: session), .fail(.agentBusy))
        o = agent()
        o.activity = .needsInput // typing would answer a permission prompt
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: o, elapsed: 1, expect: session), .wait)
        o = agent()
        o.subagentRunning = true
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: o, elapsed: 1, expect: session), .wait)
        o = agent()
        o.screenUnchangedFor = 1.9
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: o, elapsed: 1, expect: session), .wait)
        o = agent()
        o.accountSwitchInProgress = true
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: o, elapsed: 1, expect: session), .wait)
        o = agent()
        o.resumeQueued = true
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: o, elapsed: 1, expect: session), .wait)
        o = agent()
        o.choiceOnScreen = true
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: o, elapsed: 1, expect: session), .wait)
    }

    func testOnlyTheExpectedSession() {
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: agent("other"), elapsed: 1, expect: session),
                       .skip(.differentSession))
        // Not reported yet (just resumed): wait for it, never paste blind.
        let resumed = T.Expectation(sessionID: "abc", startsAgent: true, ownsPane: false)
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: agent(nil), elapsed: 5, expect: resumed), .wait)
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: agent(nil), elapsed: 120, expect: resumed), .fail(.agentDidNotStart))
        var codex = agent()
        codex.agent = .codex
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: codex, elapsed: 1, expect: session), .skip(.notClaude))
    }

    func testAgentStartingOrGone() {
        // After typing `claude`: the shell is still in front for a moment.
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: shell, elapsed: 2, expect: owned), .wait)
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: shell, elapsed: 120, expect: owned), .fail(.agentDidNotStart))
        // A queued resume will start it.
        var queued = shell
        queued.resumeQueued = true
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: queued, elapsed: 2, expect: session), .wait)
        // The session's Claude Code quit before the run could type.
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: shell, elapsed: 2, expect: session), .skip(.agentNotRunning))
        var other = T.Observation()
        other.foreground = .other
        XCTAssertEqual(T.step(state: .waitingForAgent, observation: other, elapsed: 2, expect: session), .skip(.otherProgram))
    }

    // MARK: typing, confirming

    func testReturnFollowsThePaste() {
        XCTAssertEqual(T.step(state: .typing, observation: agent(), elapsed: 0.1), .wait)
        XCTAssertEqual(T.step(state: .typing, observation: agent(), elapsed: 0.4), .enter)
        // Never Return into a shell: Claude Code quit after the paste.
        XCTAssertEqual(T.step(state: .typing, observation: shell, elapsed: 0.4), .fail(.agentNotRunning))
    }

    func testConfirming() {
        var o = agent()
        XCTAssertEqual(T.step(state: .confirming, observation: o, elapsed: 1), .wait)
        o.promptSubmitted = true
        XCTAssertEqual(T.step(state: .confirming, observation: o, elapsed: 1), .succeed(.confirmed))
        XCTAssertEqual(T.step(state: .confirming, observation: agent(), elapsed: 20), .succeed(.unconfirmed))
        var closed = agent()
        closed.paneExists = false
        XCTAssertEqual(T.step(state: .confirming, observation: closed, elapsed: 1), .succeed(.unconfirmed))
    }

    func testFinalStatesDoNothing() {
        for state in ScheduleRunState.allCases where !state.isActive {
            XCTAssertEqual(T.step(state: state, observation: shell, elapsed: 100), .wait)
        }
    }

    // MARK: screen

    func testChoiceOnScreen() {
        XCTAssertTrue(T.showsChoice(screen: """
             Do you trust the files in this folder?

             ❯ 1. Yes, proceed
               2. No, exit
            """))
        XCTAssertTrue(T.showsChoice(screen: "│ ❯ 1. Yes\n│   2. Yes, and don't ask again\n│   3. No"))
        XCTAssertFalse(T.showsChoice(screen: "╭────╮\n│ >  │\n╰────╯\n  ? for shortcuts"))
        XCTAssertFalse(T.showsChoice(screen: "> 1+1 is 2"))
        XCTAssertFalse(T.showsChoice(screen: "user@mac ~ % "))
    }

    // MARK: Which pane holds the session (#55)

    func testSessionPaneKeepsTheChosenPane() {
        // Two panes hold the same session: the schedule's own pane gets the prompt, not the first one.
        XCTAssertEqual(T.sessionPane(preferred: "p2", running: ["p1", "p2"], remembering: []), .pane("p2"))
        XCTAssertEqual(T.sessionPane(preferred: "p2", running: [], remembering: ["p1", "p2"]), .pane("p2"))
        // Ambiguous without it (its id is stale after a restart, or none was given): skipped.
        XCTAssertEqual(T.sessionPane(preferred: "p9", running: ["p1", "p2"], remembering: []), .ambiguous)
        XCTAssertEqual(T.sessionPane(preferred: nil, running: [], remembering: ["p1", "p2"]), .ambiguous)
    }

    func testSessionPaneRunningWins() {
        XCTAssertEqual(T.sessionPane(preferred: nil, running: ["p1"], remembering: []), .pane("p1"))
        XCTAssertEqual(T.sessionPane(preferred: "p9", running: [], remembering: ["p3"]), .pane("p3"))
        // Never a second copy: a pane running the session wins over the chosen pane that only remembers it.
        XCTAssertEqual(T.sessionPane(preferred: "p2", running: ["p1"], remembering: ["p2"]), .pane("p1"))
        XCTAssertEqual(T.sessionPane(preferred: nil, running: ["p1"], remembering: ["p2", "p3"]), .pane("p1"))
        XCTAssertEqual(T.sessionPane(preferred: "p1", running: [], remembering: []), .none)
    }
}
