import AppKit
import CmdsCore

/// `sendText` runs: text typed into the pane the target names now (`PaneTags.swift`), never a guess.
extension ScheduleRunner {
    /// The target's pane, then the shell command (at an empty prompt) or the agent prompt (into an idle Claude Code or
    /// Codex, whichever runs there).
    func beginSend(_ run: ActiveScheduleRun, _ action: SendText, now: Date) {
        let resolution = controller.resolveScheduleTarget(action.target)
        guard case .pane(let paneID) = resolution, let pane = controller.pane(id: paneID) else {
            return finish(run, .skipped, resolution.problem ?? .paneNotFound)
        }
        guard claim(pane, for: run) else { return }
        let stage: ActiveScheduleRun.Stage
        switch action.to {
        case .shell: stage = .shell(command: action.text, resume: nil)
        case .agent: stage = .agent(prompt: action.text)
        }
        // After a restart the pane's agent is not back yet: its session is still offered for resume.
        let awaitsResume = action.to == .agent && pane.agentUsage == nil && pane.resumeOffer != nil
        plan(run, [stage], expect: ScheduleRunTiming.Expectation(agent: nil, startsAgent: false, ownsPane: false,
                                                                 awaitsResume: awaitsResume), now: now)
    }
}
