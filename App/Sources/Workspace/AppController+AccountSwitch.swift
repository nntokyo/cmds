import AppKit
import CmdsCore

/// Moving a pane's Claude Code session to another account (docs/guide/ai-agents.md "Several Claude accounts"): the
/// offer after a limit (banner, notification), the switch itself (wait until idle, Ctrl-C, resume under the next
/// account; timing in `ClaudeAccountSwitchTiming`) and the pane's account banner. Accounts and limits:
/// AppController+Accounts.
extension AppController {
    static let accountNotificationCategory = "cmds.accountLimit"
    static let accountSwitchAction = "cmds.switchAccount"
    /// Every other account is limited: "Continue When It Resets" schedules a `continue` (App/Sources/Schedule).
    static let accountLimitLaterCategory = "cmds.accountLimitLater"
    static let continueAtResetAction = "cmds.continueAtReset"

    // MARK: Offering

    /// Offers (or, with `autoSwitch`, starts) moving the pane's session to the next free account. `notify` false:
    /// only refreshes the offer (after sharing, or when the chosen account is no longer free).
    func offerAccountSwitch(_ pane: Pane, from: String?, notify: Bool = true, now: Date = Date()) {
        let target = ClaudeAccounts.next(after: from, in: claudeAccounts.accounts, now: now)
        let session = switchableSession(pane)
        let problem = switchProblem(pane, session: session, target: target)
        var change = AccountSwitch(from: from, to: target?.name, session: session, phase: .offered(problem: problem))
        let fromName = AccountSwitch.displayName(from)
        if problem == nil, notify, claudeAccounts.autoSwitch, let target {
            change.phase = .waitingForIdle
            pane.accountSwitch = change
            updateResumeBanner(pane)
            startAccountSwitchTimer()
            raiseAttention(pane: pane, title: Self.accountLimitTitle,
                           body: String(localized: "“\(fromName)” hit its limit. Continuing with “\(target.name)” once Claude Code is idle."))
            return
        }
        pane.accountSwitch = change
        updateResumeBanner(pane)
        guard notify else { return }
        let body: String
        if let problem {
            body = String(localized: "“\(fromName)” hit its limit. \(problem.localized)")
        } else {
            body = String(localized: "“\(fromName)” hit its limit. Continue with “\(target?.name ?? "")”?")
        }
        let category: String?
        if problem == nil {
            category = Self.accountNotificationCategory
        } else {
            category = continueAtResetTime(pane) != nil ? Self.accountLimitLaterCategory : nil
        }
        raiseAttention(pane: pane, title: Self.accountLimitTitle, body: body, category: category)
    }

    /// The title of the notifications about a limit.
    private static var accountLimitTitle: String { String(localized: "Claude account limit") }

    /// The account whose limit the pane is about: the one a switch started from, else the pane's current account.
    func limitedAccount(of pane: Pane) -> String? {
        pane.accountSwitch?.from ?? currentAccount(of: pane)
    }

    /// The Claude Code session to continue: the one seen in the pane now, else the one an earlier offer kept (Claude
    /// Code may have exited since), else one offered for resuming.
    private func switchableSession(_ pane: Pane) -> AgentSession? {
        if let session = pane.agentSession, session.agent == .claude { return session }
        if let session = pane.accountSwitch?.session { return session }
        if let offer = pane.resumeOffer, offer.agent == .claude { return offer }
        return nil
    }

    private func switchProblem(_ pane: Pane, session: AgentSession?, target: ClaudeAccount?) -> AccountSwitchProblem? {
        guard pane.ssh == nil else { return .notLocal }
        guard let session, session.host == nil else { return .noSession }
        guard let target else { return .noOtherAccount }
        guard ClaudeSessionSharing.transcriptReachable(sessionID: session.sessionID, configDir: target.configDir) else {
            return .notShared(account: target.name)
        }
        return nil
    }

    // MARK: Switching

    /// `account.switch` / the banner / the notification: continue the pane's session with `to` (default: the next
    /// free account) once Claude Code is idle. Returns the account.
    @discardableResult
    func requestAccountSwitch(paneID: String?, to name: String?) throws -> String {
        let pane = try resolvePane(paneID)
        guard pane.kind == .terminal else { throw RPCError.invalidParams("pane \(pane.id) is not a terminal") }
        let from = limitedAccount(of: pane)
        let target: ClaudeAccount?
        if let name {
            target = try account(named: name)
            if target?.name == from, from != nil { throw RPCError.invalidParams("pane \(pane.id) already uses \(name)") }
        } else {
            target = ClaudeAccounts.next(after: from, in: claudeAccounts.accounts)
        }
        let session = switchableSession(pane)
        if let problem = switchProblem(pane, session: session, target: target) { throw RPCError.invalidParams(problem.english) }
        guard let target else { throw RPCError.invalidParams(AccountSwitchProblem.noOtherAccount.english) }
        if pane.accountSwitch?.isInProgress == true, pane.accountSwitch?.to == target.name { return target.name }
        pane.accountSwitch = AccountSwitch(from: from, to: target.name, session: session, phase: .waitingForIdle)
        updateResumeBanner(pane)
        startAccountSwitchTimer()
        return target.name
    }

    /// The banner's Continue and the notification's action: the offered account. When it cannot be used any more
    /// (it hit its limit meanwhile, sessions are not shared…), the offer is worked out again and shown instead.
    func continueAccountSwitch(_ pane: Pane) {
        guard let change = pane.accountSwitch else { return }
        do {
            try requestAccountSwitch(paneID: pane.id, to: change.to)
        } catch {
            offerAccountSwitch(pane, from: change.from, notify: false)
        }
    }

    /// Dismiss / Cancel: nothing more is sent to the pane.
    func dismissAccountSwitch(_ pane: Pane) {
        guard pane.accountSwitch != nil else { return }
        pane.accountSwitch = nil
        updateResumeBanner(pane)
    }

    private func startAccountSwitchTimer() {
        guard accountSwitchTimer == nil else { return }
        let timer = Timer(timeInterval: ClaudeAccountSwitchTiming.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.accountSwitchTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        accountSwitchTimer = timer
    }

    /// Moves every switch in progress on; stops the timer when there is none.
    private func accountSwitchTick(now: Date = Date()) {
        var active = false
        for pane in workspaces.flatMap(\.orderedPanes) {
            guard let change = pane.accountSwitch, change.isInProgress else { continue }
            active = true
            guard !pane.isClosing, let terminal = pane.terminal, let group = terminal.foregroundProcessGroupID else { continue }
            let foreground = PaneProcessProbe.foreground(of: group)
            if foreground == .shell, !PaneProcessProbe.agentOnTerminal(of: group) {
                finishAccountSwitch(pane, change, now: now)
            } else if change.phase == .waitingForIdle {
                quitWhenIdle(pane, change, terminal: terminal, foreground: foreground, now: now)
            } else if change.phase == .quitting {
                keepQuitting(pane, change, terminal: terminal, agentInForeground: foreground == .agent, now: now)
            }
        }
        if !active {
            accountSwitchTimer?.invalidate()
            accountSwitchTimer = nil
        }
    }

    /// `waitingForIdle`: never mid-turn. Once Claude Code is idle, the first Ctrl-C.
    private func quitWhenIdle(_ pane: Pane, _ change: AccountSwitch, terminal: TerminalSurface,
                              foreground: PaneForeground, now: Date) {
        var change = change
        let observation = pane.inputObservation(terminal, screen: terminal.visibleText(), foreground: foreground,
                                                stability: &change.screen, now: now)
        let idle = PaneReadiness.isAgentIdle(observation)
        if idle {
            terminal.sendText(ClaudeAccountSwitchTiming.interrupt)
            change.phase = .quitting
            change.interrupts = 1
            change.lastInterruptAt = now
        }
        pane.accountSwitch = change
        if idle { updateResumeBanner(pane) }
    }

    /// `quitting`: more Ctrl-Cs until the shell is back, or give up and say so.
    private func keepQuitting(_ pane: Pane, _ change: AccountSwitch, terminal: TerminalSurface, agentInForeground: Bool,
                              now: Date) {
        var change = change
        let sinceLast = now.timeIntervalSince(change.lastInterruptAt ?? now)
        switch ClaudeAccountSwitchTiming.quitStep(interrupts: change.interrupts, sinceLast: sinceLast,
                                                  agentInForeground: agentInForeground) {
        case .wait:
            return
        case .interrupt:
            terminal.sendText(ClaudeAccountSwitchTiming.interrupt)
            change.interrupts += 1
            change.lastInterruptAt = now
            pane.accountSwitch = change
        case .giveUp:
            change.phase = .offered(problem: .didNotQuit)
            pane.accountSwitch = change
            updateResumeBanner(pane)
            raiseAttention(pane: pane, title: Self.accountLimitTitle, body: AccountSwitchProblem.didNotQuit.localized)
        }
    }

    /// Claude Code has exited: hand the session to the resume machinery under the new account.
    private func finishAccountSwitch(_ pane: Pane, _ change: AccountSwitch, now: Date) {
        func fail(_ problem: AccountSwitchProblem) {
            var failed = change
            failed.phase = .offered(problem: problem)
            pane.accountSwitch = failed
            updateResumeBanner(pane)
        }
        guard let name = change.to, let target = claudeAccounts.account(named: name) else { return fail(.noOtherAccount) }
        guard var session = change.session else { return fail(.noSession) }
        session.account = target.name
        session.configDir = ClaudeAccounts.expandedPath(target.configDir)
        session.lastSeen = now
        guard AgentResume.command(for: session) != nil else { return fail(.noSession) }
        pane.accountSwitch = nil
        // The agent is gone (as when its process is seen exiting).
        pane.agentUsage = nil
        pane.agentSource = nil
        pane.agentSignals.hasUsage = false
        pane.agentSignals.endedAt = now
        dropSubagents(of: pane)
        pane.claudeAccount = target.name
        pane.agentSession = session
        pane.resumeOffer = session
        pane.resumeRequestedAt = now
        updateAgentActivity(pane, now: now, emitChange: false)
        updateResumeBanner(pane)
        startResumeTimerIfNeeded()
        scheduleSave()
        emit(.pane(workspaceID: pane.workspaceID, paneID: pane.id))
        let from = AccountSwitch.displayName(change.from)
        raiseAttention(pane: pane, title: String(localized: "Claude account switched"),
                       body: String(localized: "Continuing the session with “\(target.name)” (was “\(from)”)."))
    }

    // MARK: Banner

    /// Shows the pane's account banner; false when it has none (the resume banner may show instead).
    func showAccountBanner(_ pane: Pane) -> Bool {
        guard let change = pane.accountSwitch else { return false }
        let from = AccountSwitch.displayName(change.from)
        let reset = change.from.flatMap { claudeAccounts.account(named: $0)?.limit }.map(Self.localizedReset)
        let lead = reset.map { String(localized: "“\(from)” hit its limit (\($0)).") } ?? String(localized: "“\(from)” hit its limit.")
        let banner: AccountSwitchBannerView
        switch change.phase {
        case .offered(let problem?):
            let later = problem == .noOtherAccount ? continueAtResetTime(pane).map { $0.formatted(date: .omitted, time: .shortened) } : nil
            banner = AccountSwitchBannerView(state: .problem(text: "\(lead) \(problem.localized)", canShare: problem.needsSharing,
                                                             continueAt: later))
        case .offered(nil):
            banner = AccountSwitchBannerView(state: .offered(text: lead, target: change.to ?? ""))
        case .waitingForIdle:
            banner = AccountSwitchBannerView(state: .switching(text: String(localized: "Switching to “\(change.to ?? "")” once Claude Code is idle…")))
        case .quitting:
            banner = AccountSwitchBannerView(state: .switching(text: String(localized: "Switching to “\(change.to ?? "")”: quitting Claude Code…")))
        }
        banner.onSwitch = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.continueAccountSwitch(pane)
        }
        banner.onContinueLater = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.continueWhenLimitResets(pane)
        }
        banner.onDismiss = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.dismissAccountSwitch(pane)
        }
        banner.onSettings = {
            ClaudeAccountsWindowController.shared.showWindow(nil)
        }
        pane.container.setBanner(banner)
        return true
    }

    /// `resets 15:00` / `resets Fri 09:00`, marked when estimated.
    static func localizedReset(_ limit: ClaudeAccountLimit) -> String {
        let sameDay = Calendar.current.isDate(limit.resetsAt, inSameDayAs: Date())
        let time = sameDay ? limit.resetsAt.formatted(date: .omitted, time: .shortened)
            : limit.resetsAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        return limit.estimated ? String(localized: "resets around \(time)") : String(localized: "resets \(time)")
    }
}
