import AppKit
import CmdsCore

/// A run in progress (`ScheduleRunner.active`).
@MainActor
final class ActiveScheduleRun {
    /// What is left to type: a shell command (at an empty prompt), then a prompt (into an idle agent).
    enum Stage {
        /// `resume`: the session to record in the pane once its resume command is typed.
        case shell(command: String, resume: AgentSession?)
        case agent(prompt: String)
    }

    var record: ScheduleRun
    /// The schedule as it was when the run started.
    let schedule: Schedule
    var stateSince: Date
    var stages: [Stage] = []
    var expect = ScheduleRunTiming.Expectation()
    /// `startWorkspace` with `account: auto` (the account is chosen when the run gets past waitingForAccount).
    var automaticAccount = false
    /// The pane's screen and since when it has looked like that (reset on every state change).
    var screen = ScreenStability()
    var enterAt: Date?

    init(record: ScheduleRun, schedule: Schedule, now: Date) {
        self.record = record
        self.schedule = schedule
        stateSince = now
    }
}

/// Driving runs: `ScheduleRunTiming.step` decides from an `Observation` of the pane; this file only looks and types.
/// How each action begins: startWorkspace below, `continueSession` in ScheduleRunner+ContinueSession.swift, `sendText`
/// in ScheduleRunner+SendText.swift.
extension ScheduleRunner {
    // MARK: Starting

    @discardableResult
    func startRun(_ schedule: Schedule, cause: ScheduleRun.Cause, dueAt: Date) -> ScheduleRun {
        if let refusal = refusal(of: schedule) {
            let record = recordEndedRun(of: schedule, cause: cause, dueAt: dueAt,
                                        state: refusal == .invalidSchedule ? .failed : .skipped, reason: refusal, notify: true)
            log(record)
            return record
        }
        let now = now()
        let record = ScheduleRun(id: newRunID(), scheduleID: schedule.id, scheduleName: schedule.name, cause: cause,
                                 dueAt: dueAt, startedAt: now, state: .waitingForAccount)
        let run = ActiveScheduleRun(record: record, schedule: schedule, now: now)
        run.record.account = runAccount(run)
        active.append(run)
        log(run.record)
        emit(.run(run.record))
        step(run, now: now)
        startTickTimerIfNeeded()
        return run.record
    }

    /// Why a run of `schedule` does not start: one active run per schedule, `maxActiveRuns` in all, a valid schedule.
    private func refusal(of schedule: Schedule) -> ScheduleReason? {
        if active.contains(where: { $0.record.scheduleID == schedule.id }) { return .previousRunActive }
        if active.count >= ScheduleLimits.maxActiveRuns { return .tooManyRuns }
        return ScheduleValidation.problems(schedule.draft).isEmpty ? nil : .invalidSchedule
    }

    /// The account the run uses (and waits for): the action's, else the limit trigger's, else (Claude Code
    /// continueSession) the session's. A Codex session has none.
    private func runAccount(_ run: ActiveScheduleRun) -> String? {
        var triggerAccount: String?
        if case .limitReset(let account, _, _) = run.schedule.trigger { triggerAccount = account }
        switch run.schedule.action {
        case .startWorkspace(let action):
            run.automaticAccount = action.account?.lowercased() == ClaudeAccounts.automatic
            return run.automaticAccount ? nil : action.account
        case .continueSession(let action):
            guard action.agent == .claude else { return nil }
            if let account = action.account { return account }
            // "When work resets": the session continues under work (if it moved to another account, it is skipped).
            if let triggerAccount { return triggerAccount }
            guard case .pane(let pane) = sessionPane(action) else { return nil }
            return pane.claudeAccount ?? sessionRecord(action.sessionID, agent: .claude, in: pane)?.account
        case .sendText:
            // "When work resets": waits until it has.
            return triggerAccount
        }
    }

    private func startTickTimerIfNeeded() {
        guard tickTimer == nil, !active.isEmpty else { return }
        let timer = Timer(timeInterval: ScheduleRunTiming.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func tick() {
        let now = now()
        for run in active { step(run, now: now) }
        if active.isEmpty {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    // MARK: Stepping

    private func step(_ run: ActiveScheduleRun, now: Date) {
        guard active.contains(where: { $0 === run }) else { return }
        yieldToQueuedResume(run, now: now)
        let observation = observe(run, now: now)
        let decision = ScheduleRunTiming.step(state: run.record.state, observation: observation,
                                              elapsed: now.timeIntervalSince(run.stateSince), expect: run.expect)
        switch decision {
        case .wait:
            return
        case .proceed:
            begin(run, now: now)
        case .type:
            typeCommand(run, now: now)
        case .paste:
            pastePrompt(run, now: now)
        case .enter:
            pressReturn(run, now: now)
        case .succeed(let reason):
            finish(run, .succeeded, reason)
        case .fail(let reason):
            // `auto`: no account frees up in time.
            if reason == .accountStillLimited, run.automaticAccount { return finish(run, .skipped, .allAccountsLimited) }
            finish(run, .failed, reason)
        case .skip(let reason):
            finish(run, .skipped, reason)
        }
    }

    /// Before typing the resume into a pane, a resume the user queued meanwhile does it instead.
    private func yieldToQueuedResume(_ run: ActiveScheduleRun, now: Date) {
        guard run.record.state == .waitingForPane, case .shell(_, let resume?)? = run.stages.first,
              let pane = run.record.pane.flatMap(controller.pane(id:)), pane.resumeRequestedAt != nil,
              pane.resumeOffer?.sessionID == resume.sessionID else { return }
        run.stages.removeFirst()
        run.expect.startsAgent = true
        move(run, to: .waitingForAgent, now: now)
    }

    func move(_ run: ActiveScheduleRun, to state: ScheduleRunState, now: Date) {
        run.record.state = state
        run.stateSince = now
        run.screen.reset()
        log(run.record)
        emit(.run(run.record))
    }

    /// What the run's pane shows now (or, while waiting for an account, whether it is free).
    private func observe(_ run: ActiveScheduleRun, now: Date) -> ScheduleRunTiming.Observation {
        var o = ScheduleRunTiming.Observation()
        if run.record.state == .waitingForAccount {
            observeAccount(run, into: &o, now: now)
            return o
        }
        guard let paneID = run.record.pane, let pane = controller.pane(id: paneID), !pane.isClosing,
              let terminal = pane.terminal else {
            o.paneExists = false
            return o
        }
        let (foreground, group) = pane.inputForeground(terminal, now: now)
        let screen = terminal.visibleText()
        o.pane = pane.inputObservation(terminal, screen: screen, foreground: foreground, stability: &run.screen, now: now)
        // Looked up only where it decides something (it lists every process): before typing into a shell, and to
        // tell a quit agent from a backgrounded one.
        if foreground == .shell, let group,
           run.record.state == .waitingForPane || run.record.state == .waitingForAgent {
            o.agentOnTerminal = PaneProcessProbe.agentOnTerminal(of: group)
        }
        if foreground == .agent {
            // Which agent: its process, else what it reports.
            o.agent = group.flatMap(PaneProcessProbe.agentKind(of:)) ?? pane.agentUsage?.agent
            o.choiceOnScreen = ScheduleRunTiming.showsChoice(screen: screen)
            o.workingOnScreen = PaneReadiness.showsWorking(screen: screen)
        } else {
            o.agent = pane.agentUsage?.agent
        }
        if let usage = pane.agentUsage, usage.agent == o.agent {
            o.agentReported = true
            o.sessionID = usage.sessionID
        }
        o.accountSwitchInProgress = pane.accountSwitch?.isInProgress == true
        o.resumeQueued = pane.resumeRequestedAt != nil && pane.resumeOffer != nil
        if let enterAt = run.enterAt {
            o.promptSubmitted = pane.agentActivity == .busy || pane.agentSignals.workedSince(enterAt)
        }
        return o
    }

    private func observeAccount(_ run: ActiveScheduleRun, into o: inout ScheduleRunTiming.Observation, now: Date) {
        if case .codexLimitReset = run.schedule.trigger {
            // Codex is still limited (a later reset was seen meanwhile): wait for it.
            guard let reset = codexLimits?.exhaustedReset, reset > now else { return }
            o.accountLimited = true
            o.accountFreeIn = reset.timeIntervalSince(now)
            return
        }
        let accounts = controller.claudeAccounts.accounts
        if run.automaticAccount {
            guard ClaudeAccounts.firstAvailable(in: accounts, now: now) == nil else { return }
            o.accountLimited = true
            o.accountFreeIn = ScheduleRunTiming.autoAccountFreeIn(resets: accounts.compactMap { $0.limit?.resetsAt }, now: now)
            return
        }
        guard let name = run.record.account, let account = accounts.first(where: { $0.hasName(name) }),
              let limit = account.limit, limit.isActive(at: now) else { return }
        o.accountLimited = true
        o.accountFreeIn = limit.resetsAt.timeIntervalSince(now)
    }

    // MARK: Actions

    /// The account is free: open the workspace, or find the session's pane.
    private func begin(_ run: ActiveScheduleRun, now: Date) {
        let accounts = controller.claudeAccounts.accounts
        if run.automaticAccount {
            guard let account = ClaudeAccounts.firstAvailable(in: accounts, now: now) else {
                return finish(run, .skipped, .allAccountsLimited)
            }
            run.record.account = account.name
        } else if let name = run.record.account, !accounts.contains(where: { $0.hasName(name) }) {
            // The run's account was removed (a session's own account that is not one of the user's accounts is fine).
            if run.accountIsRequired { return finish(run, .failed, .accountRemoved) }
            run.record.account = nil
        }
        let account = run.record.account.flatMap { name in accounts.first { $0.hasName(name) } }
        switch run.schedule.action {
        case .startWorkspace(let action):
            guard let cwd = existingFolder(action.cwd) else { return finish(run, .failed, .folderMissing) }
            openWorkspace(for: run, title: action.title ?? run.schedule.name, cwd: cwd, account: account)
            guard let command = action.command else { return finish(run, .succeeded, .workspaceOpened) }
            plan(run, [.shell(command: command, resume: nil)] + (action.prompt.map { [.agent(prompt: $0)] } ?? []),
                 expect: ScheduleRunTiming.Expectation(sessionID: nil, startsAgent: true, ownsPane: true), now: now)
        case .continueSession(let action):
            beginContinue(run, action, account: account, now: now)
        case .sendText(let action):
            beginSend(run, action, now: now)
        }
    }

    /// What the run types, in order, and what it expects of its pane: it waits for an empty shell prompt when the first
    /// stage is a command, else for the agent.
    func plan(_ run: ActiveScheduleRun, _ stages: [ActiveScheduleRun.Stage], expect: ScheduleRunTiming.Expectation, now: Date) {
        run.stages = stages
        run.expect = expect
        if case .shell? = stages.first {
            move(run, to: .waitingForPane, now: now)
        } else {
            move(run, to: .waitingForAgent, now: now)
        }
    }

    /// The run uses `pane` (an existing pane: a `sendText` target, the pane holding a session). False when another
    /// active run uses it: the run is then skipped.
    func claim(_ pane: Pane, for run: ActiveScheduleRun) -> Bool {
        run.record.workspace = pane.workspaceID
        run.record.pane = pane.id
        guard !active.contains(where: { $0 !== run && $0.record.pane == pane.id }) else {
            finish(run, .skipped, .paneInUse)
            return false
        }
        return true
    }

    /// A new background workspace for the run (never selected; the keyboard stays where it is); its pane is the run's.
    func openWorkspace(for run: ActiveScheduleRun, title: String, cwd: String, account: ClaudeAccount?) {
        let info = controller.createWorkspace(title: title, cwd: cwd, account: account, select: false)
        run.record.workspace = info.id
        run.record.pane = info.panes.first?.id
    }

    /// Types the stage's command once. The run moves on whatever happens next: nothing is typed twice.
    private func typeCommand(_ run: ActiveScheduleRun, now: Date) {
        guard case .shell(let command, let resume)? = run.stages.first,
              let pane = run.record.pane.flatMap(controller.pane(id:)), let terminal = pane.terminal else {
            return finish(run, .failed, .paneClosed)
        }
        run.stages.removeFirst()
        if let resume {
            // The resume banner must not type it as well; the pane now holds this session (under the run's account).
            if pane.resumeOffer != nil { controller.clearResumeOffer(pane) }
            pane.agentSession = resume
            pane.resumedSessionID = resume.sessionID
            if let name = resume.account { pane.claudeAccount = name }
            controller.scheduleSave()
        }
        terminal.typeText(command + "\r")
        guard !run.stages.isEmpty else { return finish(run, .succeeded, .commandTyped) }
        move(run, to: .waitingForAgent, now: now)
    }

    private func pastePrompt(_ run: ActiveScheduleRun, now: Date) {
        guard case .agent(let prompt)? = run.stages.first, let terminal = terminal(of: run) else {
            return finish(run, .failed, .paneClosed)
        }
        run.stages.removeFirst()
        // A paste (bracketed when Claude Code asks for it), so line breaks stay in the prompt; Return follows.
        terminal.sendText(prompt)
        move(run, to: .typing, now: now)
    }

    private func pressReturn(_ run: ActiveScheduleRun, now: Date) {
        guard let terminal = terminal(of: run) else { return finish(run, .failed, .paneClosed) }
        terminal.sendText("\r")
        run.enterAt = now
        move(run, to: .confirming, now: now)
    }

    func finish(_ run: ActiveScheduleRun, _ state: ScheduleRunState, _ reason: ScheduleReason, notify shouldNotify: Bool = true) {
        guard let index = active.firstIndex(where: { $0 === run }) else { return }
        active.remove(at: index)
        run.record.state = state
        run.record.reason = reason
        run.record.endedAt = now()
        log(run.record)
        addToHistory(run.record)
        emit(.run(run.record))
        emit(.schedules(id: run.record.scheduleID))
        if shouldNotify { notify(run.record, schedule: schedule(id: run.schedule.id) ?? run.schedule) }
    }

    // MARK: Helpers

    private func terminal(of run: ActiveScheduleRun) -> TerminalSurface? {
        guard let pane = run.record.pane.flatMap(controller.pane(id:)), !pane.isClosing else { return nil }
        return pane.terminal
    }

    func existingFolder(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return expanded
    }

    /// Ids, states and reason codes only; never prompts or commands.
    private func log(_ run: ScheduleRun) {
        scheduleLog.info("run \(run.id, privacy: .public) of \(run.scheduleID, privacy: .public): \(run.state.rawValue, privacy: .public) \(run.reason?.rawValue ?? "", privacy: .public) pane \(run.pane ?? "-", privacy: .public)")
    }
}

extension ActiveScheduleRun {
    /// The schedule names the account itself (its absence is an error); a session's remembered account may be gone.
    var accountIsRequired: Bool {
        switch schedule.action {
        case .startWorkspace(let action): return action.account != nil
        case .continueSession(let action):
            if action.account != nil { return true }
            if action.agent == .claude, case .limitReset = schedule.trigger { return true }
            return false
        case .sendText:
            if case .limitReset = schedule.trigger { return true }
            return false
        }
    }
}
