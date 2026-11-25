import XCTest
@testable import CmdsCore

/// From Claude Code's hooks to the decision to type: an agent that finished a turn and has waited at its prompt for
/// minutes or hours gets a schedule's prompt and a kept instruction. (0.35.0 and 0.36.0 typed only into agents that
/// had answered less than a minute before: the idle notice Claude Code sends after 60 s was taken for a question.)
final class IdleAgentDeliveryTests: XCTestCase {
    private let turnEnded = Date(timeIntervalSince1970: 1_795_000_000)

    private func event(_ json: String) -> ClaudeHook.Event {
        ClaudeHook.event(fromHookInput: Data(json.utf8), readTranscript: false)!
    }

    /// The pane's signals after the hooks `events` (seconds after the turn ended, payload), as the app records them.
    private func signals(after events: [(TimeInterval, String)]) -> AgentSignals {
        var signals = AgentSignals()
        signals.hasUsage = true
        for (offset, json) in events {
            let parsed = event(json)
            // What the CLI forwards is what the app reads.
            let forwarded = try! JSONEncoder().encode(ClaudeHook.forwardedInput(fromHookInput: Data(json.utf8), event: parsed))
            guard let state = ClaudeHook.event(fromHookInput: forwarded, readTranscript: false)?.hookState else { continue }
            signals.hook = state
            signals.hookAt = turnEnded.addingTimeInterval(offset)
        }
        return signals
    }

    /// What a run or the queue sees in the pane `minutes` after the turn ended: Claude Code in the foreground, its
    /// screen still, its input box on screen and empty.
    private func observation(_ signals: AgentSignals, minutes: Double) -> ScheduleRunTiming.Observation {
        var o = ScheduleRunTiming.Observation()
        o.foreground = .agent
        o.agentOnTerminal = true
        o.agent = .claude
        o.agentReported = true
        o.sessionID = "abc"
        o.activity = signals.activity(at: turnEnded.addingTimeInterval(minutes * 60))
        o.screenUnchangedFor = minutes * 60
        return o
    }

    private let stop = #"{"hook_event_name":"Stop","last_assistant_message":"Done."}"#
    private let idleNotice = #"{"hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt"}"#
    private let idleNoticeOld = #"{"hook_event_name":"Notification","message":"Claude is waiting for your input"}"#
    private let permission = #"{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}"#

    func testAgentIdleForMinutesOrHoursIsTypedInto() {
        for notice in [idleNotice, idleNoticeOld] {
            let waiting = signals(after: [(0, stop), (60, notice)])
            for minutes: Double in [1.5, 2, 5, 30, 60, 480, 1440] {
                let o = observation(waiting, minutes: minutes)
                XCTAssertEqual(o.activity, .idle, "\(minutes) min")
                // A schedule's `--send … --to agent` and `--continue`.
                XCTAssertEqual(ScheduleRunTiming.step(state: .waitingForAgent, observation: o, elapsed: 0,
                                                      expect: .init(agent: nil)), .paste, "\(minutes) min")
                XCTAssertEqual(ScheduleRunTiming.step(state: .waitingForAgent, observation: o, elapsed: 0,
                                                      expect: .init(sessionID: "abc")), .paste, "\(minutes) min")
                // `cmds queue add`.
                XCTAssertEqual(PaneQueueTiming.step(phase: .waiting, observation: o, elapsed: 0), .paste, "\(minutes) min")
            }
        }
    }

    func testAgentIdleBeforeTheNoticeIsTypedInto() {
        let o = observation(signals(after: [(0, stop)]), minutes: 0.5)
        XCTAssertEqual(ScheduleRunTiming.step(state: .waitingForAgent, observation: o, elapsed: 0, expect: .init(agent: nil)), .paste)
        XCTAssertEqual(PaneQueueTiming.step(phase: .waiting, observation: o, elapsed: 0), .paste)
    }

    /// A real question is still never answered by a schedule or a kept instruction, however long it has stood.
    func testAgentAskingForPermissionIsNeverTypedInto() {
        let asking = signals(after: [(0, permission)])
        for minutes: Double in [0.5, 5, 60, 1440] {
            let o = observation(asking, minutes: minutes)
            XCTAssertEqual(o.activity, .needsInput, "\(minutes) min")
            XCTAssertEqual(ScheduleRunTiming.step(state: .waitingForAgent, observation: o, elapsed: 0, expect: .init(agent: nil)), .wait)
            XCTAssertEqual(PaneQueueTiming.step(phase: .waiting, observation: o, elapsed: 0), .hold(.needsInput))
        }
        // The idle notice after a question that was answered and worked on does not bring the question back.
        let answered = signals(after: [(0, permission), (30, #"{"hook_event_name":"PostToolUse"}"#), (40, stop), (100, idleNotice)])
        XCTAssertEqual(PaneQueueTiming.step(phase: .waiting, observation: observation(answered, minutes: 10), elapsed: 0), .paste)
    }
}
