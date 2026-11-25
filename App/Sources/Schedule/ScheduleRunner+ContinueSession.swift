import AppKit
import CmdsCore

/// `continueSession` runs: the pane holding the Claude Code or Codex session gets the prompt; a session that is not
/// running is resumed first, in its pane or in a new background workspace.
extension ScheduleRunner {
    func beginContinue(_ run: ActiveScheduleRun, _ action: ContinueSession, account: ClaudeAccount?, now: Date) {
        let id = action.sessionID
        let pane: Pane
        switch sessionPane(action) {
        case .pane(let found):
            pane = found
        case .ambiguous:
            // Several panes hold it and the schedule's own pane is not one of them: never guess.
            return finish(run, .skipped, .ambiguousSession)
        case .none:
            // (c) No pane holds it: resume it in a new background workspace.
            guard let folder = action.cwd else { return finish(run, .failed, .sessionNotFound) }
            guard let cwd = existingFolder(folder) else { return finish(run, .failed, .folderMissing) }
            let session = resumeSession(action, cwd: cwd, account: account, remembered: nil, now: now)
            guard let command = AgentResume.command(for: session) else { return finish(run, .failed, .resumeNotPossible) }
            openWorkspace(for: run, title: run.schedule.name, cwd: cwd, account: account)
            return plan(run, [.shell(command: command, resume: session), .agent(prompt: action.prompt)],
                        expect: ScheduleRunTiming.Expectation(agent: action.agent, sessionID: id, startsAgent: true, ownsPane: true),
                        now: now)
        }
        guard claim(pane, for: run) else { return }
        if let usage = pane.agentUsage {
            // (a) Running: only the same session, under the run's account (else an automatic switch moved it).
            guard usage.agent == action.agent, usage.sessionID == id else { return finish(run, .skipped, .differentSession) }
            if action.agent == .claude, let wanted = run.record.account, let current = controller.currentAccount(of: pane),
               current.caseInsensitiveCompare(wanted) != .orderedSame {
                return finish(run, .skipped, .movedToOtherAccount)
            }
            return plan(run, [.agent(prompt: action.prompt)],
                        expect: ScheduleRunTiming.Expectation(agent: action.agent, sessionID: id, startsAgent: false, ownsPane: false),
                        now: now)
        }
        if pane.resumeRequestedAt != nil, pane.resumeOffer?.sessionID == id {
            // A resume is queued already: it starts the agent; the prompt follows.
            return plan(run, [.agent(prompt: action.prompt)],
                        expect: ScheduleRunTiming.Expectation(agent: action.agent, sessionID: id, startsAgent: true, ownsPane: false),
                        now: now)
        }
        // (b) At a shell: type the resume command (under the run's account), then the prompt.
        let remembered = sessionRecord(id, agent: action.agent, in: pane)
        let cwd = remembered?.cwd ?? action.cwd
        let session = resumeSession(action, cwd: cwd, account: account, remembered: remembered, now: now)
        guard let command = AgentResume.command(for: session) else { return finish(run, .failed, .resumeNotPossible) }
        plan(run, [.shell(command: command, resume: session), .agent(prompt: action.prompt)],
             expect: ScheduleRunTiming.Expectation(agent: action.agent, sessionID: id, startsAgent: true, ownsPane: false),
             now: now)
    }

    enum SessionPane {
        case pane(Pane)
        case none
        case ambiguous
    }

    /// The local terminal pane holding the action's session (`ScheduleRunTiming.sessionPane`): running it, else
    /// remembering or offering it; the schedule's own pane first.
    func sessionPane(_ action: ContinueSession) -> SessionPane {
        let id = action.sessionID
        let panes = controller.workspaces.flatMap(\.orderedPanes).filter(AppController.isScheduleTarget)
        let running = panes.filter { $0.agentUsage?.agent == action.agent && $0.agentUsage?.sessionID == id }
        let remembering = panes.filter { pane in
            !running.contains { $0 === pane } && sessionRecord(id, agent: action.agent, in: pane) != nil
        }
        // The schedule's own pane, by its tag (pane ids change when cmds restarts).
        var preferred: String?
        if let tag = action.paneTag, case .pane(let id) = controller.resolveScheduleTarget(.tag(tag)) { preferred = id }
        switch ScheduleRunTiming.sessionPane(preferred: preferred, running: running.map(\.id),
                                             remembering: remembering.map(\.id)) {
        case .pane(let paneID): return panes.first { $0.id == paneID }.map(SessionPane.pane) ?? .none
        case .none: return .none
        case .ambiguous: return .ambiguous
        }
    }

    func sessionRecord(_ id: String, agent: AgentKind, in pane: Pane) -> AgentSession? {
        [pane.resumeOffer, pane.agentSession].compactMap { $0 }.first { $0.agent == agent && $0.sessionID == id }
    }

    /// The session to resume: its remembered details, under `account` (else the account it had; Claude Code only).
    private func resumeSession(_ action: ContinueSession, cwd: String?, account: ClaudeAccount?, remembered: AgentSession?,
                               now: Date) -> AgentSession {
        var session = remembered ?? AgentSession(agent: action.agent, sessionID: action.sessionID)
        session.cwd = cwd.map { ($0 as NSString).expandingTildeInPath } ?? session.cwd
        session.lastSeen = now
        if action.agent == .claude, let account {
            session.account = account.name
            session.configDir = ClaudeAccounts.expandedPath(account.configDir)
        }
        return session
    }
}

// MARK: After a restart

extension ScheduleRunner {
    /// What a session cut off by cmds quitting is told once it is resumed when nothing else was worked out.
    static let restartPrompt = ResumeNote.prompt(reason: .restart, cutOff: true, jobs: []) ?? "continue"

    /// Sessions restored as cut off while working (`Pane.continueAfterResume`): each gets one `continueSession` run
    /// with `restartPrompt`, typed only when it is idle, like a schedule's (it waits for the queued resume). Not a
    /// stored schedule: the run shows in the history as "Continue after cmds restarted". At most `maxActiveRuns` are at
    /// work at a time; the others wait for a slot (`ScheduleRunTiming.slotStep`).
    func continueAfterRestart() {
        for pane in controller.workspaces.flatMap(\.orderedPanes) where pane.continueAfterResume {
            guard let session = pane.resumeOffer ?? pane.agentSession else {
                pane.continueAfterResume = false
                continue
            }
            pane.continueAfterResume = false
            pane.resumeInterrupted = false
            let now = now()
            let prompt = pane.continueNote ?? Self.restartPrompt
            let name = pane.continueTitle ?? String(localized: "Continue after cmds restarted",
                                                    comment: "schedule history: an agent cut off by a restart was told to continue")
            pane.continueNote = nil
            pane.continueTitle = nil
            let draft = ScheduleDraft(name: name,
                                      trigger: .once(at: now),
                                      action: .continueSession(ContinueSession(agent: session.agent, sessionID: session.sessionID,
                                                                               cwd: session.cwd, prompt: prompt,
                                                                               paneTag: controller.scheduleTag(for: pane))),
                                      late: .skip, notify: .failures, warn: false)
            let schedule = Schedule(id: "resume-\(pane.id)", draft: draft, origin: .app, createdAt: now)
            startRun(schedule, cause: .manual, dueAt: now)
        }
    }
}
