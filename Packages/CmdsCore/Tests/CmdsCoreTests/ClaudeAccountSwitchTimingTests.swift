import XCTest
@testable import CmdsCore

/// When an account switch quits Claude Code (#31): never mid-turn, two Ctrl-Cs at once, again a few times, then give up.
final class ClaudeAccountSwitchTimingTests: XCTestCase {
    typealias Timing = ClaudeAccountSwitchTiming

    func testIdleOnlyWhenNothingIsGoingOn() {
        XCTAssertTrue(Timing.isIdle(agentInForeground: true, busy: false, subagentRunning: false, screenUnchangedFor: 2))
        XCTAssertFalse(Timing.isIdle(agentInForeground: true, busy: false, subagentRunning: false, screenUnchangedFor: 1.9))
        XCTAssertFalse(Timing.isIdle(agentInForeground: true, busy: true, subagentRunning: false, screenUnchangedFor: 60))
        XCTAssertFalse(Timing.isIdle(agentInForeground: true, busy: false, subagentRunning: true, screenUnchangedFor: 60))
        XCTAssertFalse(Timing.isIdle(agentInForeground: false, busy: false, subagentRunning: false, screenUnchangedFor: 60))
    }

    func testRetriesEveryFewSecondsAndStopAtThree() {
        XCTAssertEqual(Timing.quitStep(attempts: 1, sinceLast: 2.4, agentInForeground: true), .wait)
        XCTAssertEqual(Timing.quitStep(attempts: 1, sinceLast: 2.5, agentInForeground: true), .retry)
        XCTAssertEqual(Timing.quitStep(attempts: 2, sinceLast: 2.5, agentInForeground: true), .retry)
        XCTAssertEqual(Timing.quitStep(attempts: 3, sinceLast: 2.5, agentInForeground: true), .wait)
        XCTAssertEqual(Timing.quitStep(attempts: 3, sinceLast: 4.9, agentInForeground: true), .wait)
        XCTAssertEqual(Timing.quitStep(attempts: 3, sinceLast: 5, agentInForeground: true), .giveUp)
    }

    func testNoCtrlCWhenClaudeCodeIsNotInFront() {
        // Something else in the foreground (not the shell yet): no keys are typed into it.
        XCTAssertEqual(Timing.quitStep(attempts: 1, sinceLast: 10, agentInForeground: false), .wait)
        XCTAssertEqual(Timing.quitStep(attempts: 2, sinceLast: 10, agentInForeground: false), .wait)
        // Giving up does not depend on what is in front.
        XCTAssertEqual(Timing.quitStep(attempts: 3, sinceLast: 5, agentInForeground: false), .giveUp)
    }

    func testInterruptIsCtrlC() {
        XCTAssertEqual(Timing.interrupt.unicodeScalars.map(\.value), [3])
    }

    func testQuitIsTwoCtrlCsInOneWrite() {
        // A second Ctrl-C quits Claude Code only within about 0.7 s of the first: both go out together.
        XCTAssertEqual(Timing.quit.unicodeScalars.map(\.value), [3, 3])
    }
}
