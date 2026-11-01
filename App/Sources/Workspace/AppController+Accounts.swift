import AppKit
import CmdsCore

/// An account switch offered or in progress in a pane (`Pane.accountSwitch`).
struct AccountSwitch {
    enum Phase: Equatable {
        /// Shown in the pane's banner and notified; waits for the user. `problem`: why it cannot switch now.
        case offered(problem: AccountSwitchProblem?)
        /// Asked for (button, notification, `account.switch`, automatic): waits for Claude Code to sit idle.
        case waitingForIdle
        /// Ctrl-C sent; waits for the shell to come back.
        case quitting
    }

    /// The account that hit its limit (nil: not one of the user's accounts).
    var from: String?
    /// The account to continue with; nil when none is free.
    var to: String?
    var session: AgentSession?
    var phase: Phase
    var automatic = false
    var interrupts = 0
    var lastInterruptAt: Date?
    var screen: String?
    var screenSince: Date?

    var isInProgress: Bool { phase == .waitingForIdle || phase == .quitting }
}

/// Why a pane cannot move to another account now.
enum AccountSwitchProblem: Equatable {
    case notLocal
    case noSession
    case noOtherAccount
    case notShared(account: String)
    case didNotQuit

    /// For the API and CLI (English, docs/internals/localization.md).
    var english: String {
        switch self {
        case .notLocal: return "accounts are for local terminal panes, not SSH panes"
        case .noSession: return "no Claude Code session id is known for this pane (add `cmds hook claude-status` to the status line in the account's settings.json)"
        case .noOtherAccount: return "every other account has hit its limit (or there is no other account)"
        case .notShared(let account): return "the session's transcript is not reachable from account \(account): share sessions first (cmds accounts share)"
        case .didNotQuit: return "Claude Code did not quit (Ctrl-C); quit it yourself and run cmds accounts switch again"
        }
    }

    var localized: String {
        switch self {
        case .notLocal: return String(localized: "Accounts are for local terminal panes, not SSH panes.")
        case .noSession: return String(localized: "The session id is not known: add cmds hook claude-status to the status line in this account’s settings.json.")
        case .noOtherAccount: return String(localized: "Every other account has hit its limit.")
        case .notShared(let account): return String(localized: "The session cannot be reached from “\(account)”: share sessions in Settings › Claude Accounts first.")
        case .didNotQuit: return String(localized: "Claude Code did not quit. Quit it yourself, then try again.")
        }
    }
}

/// Several Claude Code accounts of the user (docs/guide/ai-agents.md "Several Claude accounts").
///
/// - Accounts: names and config directories (`ClaudeAccountSettings`, saved in `claude-accounts.json` in the support
///   directory). A pane created with an account gets its `CLAUDE_CONFIG_DIR`; `cmds hook claude-status` reports the
///   `CLAUDE_CONFIG_DIR` Claude Code actually runs with, which names the pane's account.
/// - Limits: every metadata scan (2 s) reads the screen of local panes running Claude Code for a limit message
///   (`ClaudeLimitDetector`); status-line windows at 100 % count too. The account's reset time is recorded.
/// - Switching: offered in the pane (banner, notification with an action), or started by itself with
///   `autoSwitch`. Once Claude Code is idle at its prompt it gets Ctrl-C (twice, as Claude Code asks); when the
///   shell is back the session is handed to the resume machinery (AppController+AgentSessions) as
///   `env CLAUDE_CONFIG_DIR='<next>' claude --resume <id>`. Only when the transcript is reachable from the next
///   account (`ClaudeSessionSharing`), never mid-turn, never in SSH panes.
extension AppController {
    static let accountsDidChange = Notification.Name("cmdsClaudeAccountsDidChange")
    /// The screen must not change for this long before Claude Code counts as idle.
    static let accountSwitchIdleTime: TimeInterval = 2
    /// The same limit line in a pane is handled once in this time (a resumed session may show it again).
    static let limitLineMemory: TimeInterval = 5 * 3600
    static let accountNotificationCategory = "cmds.accountLimit"
    static let accountSwitchAction = "cmds.switchAccount"

    // MARK: Accounts (account.*)

    func saveClaudeAccounts() {
        do {
            try ClaudeAccountStore.save(claudeAccounts, to: ClaudeAccountStore.url())
        } catch {
            NSLog("cmds: could not save Claude accounts: \(error)")
        }
        NotificationCenter.default.post(name: Self.accountsDidChange, object: nil)
    }

    func accountList(now: Date = Date()) -> ClaudeAccountList {
        let accounts = claudeAccounts.accounts
        let statuses = accounts.map { account -> ClaudeAccountStatus in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: ClaudeAccounts.expandedPath(account.configDir),
                                                        isDirectory: &isDirectory) && isDirectory.boolValue
            let panes = workspaces.flatMap(\.orderedPanes)
                .filter { $0.claudeAccount?.caseInsensitiveCompare(account.name) == .orderedSame }.map(\.id)
            return ClaudeAccountStatus(name: account.name, configDir: account.configDir, exists: exists,
                                       limit: account.isLimited(at: now) ? account.limit : nil,
                                       sessions: ClaudeSessionSharing.link(of: account, in: accounts), panes: panes)
        }
        return ClaudeAccountList(accounts: statuses, autoSwitch: claudeAccounts.autoSwitch)
    }

    func addAccount(name: String, configDir: String) throws {
        let name = name.trimmingCharacters(in: .whitespaces)
        let configDir = configDir.trimmingCharacters(in: .whitespaces)
        if let problem = ClaudeAccounts.nameProblem(name) { throw RPCError.invalidParams(problem) }
        if let problem = ClaudeAccounts.pathProblem(configDir) { throw RPCError.invalidParams(problem) }
        guard claudeAccounts.account(named: name) == nil else { throw RPCError.invalidParams("an account named \(name) exists") }
        let expanded = ClaudeAccounts.expandedPath(configDir)
        if let other = claudeAccounts.accounts.first(where: { ClaudeAccounts.expandedPath($0.configDir) == expanded }) {
            throw RPCError.invalidParams("account \(other.name) already uses \(configDir)")
        }
        guard claudeAccounts.accounts.count < ClaudeAccounts.maxAccounts else {
            throw RPCError.invalidParams("at most \(ClaudeAccounts.maxAccounts) accounts")
        }
        claudeAccounts.accounts.append(ClaudeAccount(name: name, configDir: configDir))
        saveClaudeAccounts()
    }

    /// Removes the account from cmds only; its config directory is left as it is. Panes keep running.
    func removeAccount(name: String) throws {
        let account = try account(named: name)
        claudeAccounts.accounts.removeAll { $0.name == account.name }
        for pane in workspaces.flatMap(\.orderedPanes) where pane.accountSwitch?.to == account.name && pane.accountSwitch?.isInProgress == false {
            dismissAccountSwitch(pane)
        }
        saveClaudeAccounts()
    }

    func moveAccount(name: String, to index: Int) throws {
        let account = try account(named: name)
        claudeAccounts.accounts.removeAll { $0.name == account.name }
        claudeAccounts.accounts.insert(account, at: max(0, min(index, claudeAccounts.accounts.count)))
        saveClaudeAccounts()
    }

    func setAccountAutoSwitch(_ on: Bool) {
        claudeAccounts.autoSwitch = on
        saveClaudeAccounts()
    }

    /// Forget an account's limit (the user knows it has reset, or the detection was wrong).
    func clearAccountLimit(name: String) throws {
        let account = try account(named: name)
        guard let index = claudeAccounts.accounts.firstIndex(where: { $0.name == account.name }) else { return }
        claudeAccounts.accounts[index].limit = nil
        saveClaudeAccounts()
    }

    /// `account.share`: what sharing the session transcripts would do (`apply` false) or does.
    func shareAccountSessions(apply: Bool) throws -> [ClaudeSessionSharing.Step] {
        let accounts = claudeAccounts.accounts
        let steps = ClaudeSessionSharing.plan(accounts)
        guard apply else { return steps }
        do {
            try ClaudeSessionSharing.apply(steps, accounts: accounts)
        } catch {
            NotificationCenter.default.post(name: Self.accountsDidChange, object: nil)
            throw RPCError(code: -32603, message: "sharing sessions failed: \(error)")
        }
        NotificationCenter.default.post(name: Self.accountsDidChange, object: nil)
        // Offers that waited for sharing may work now.
        for pane in workspaces.flatMap(\.orderedPanes) {
            if case .offered(.notShared?)? = pane.accountSwitch?.phase {
                offerAccountSwitch(pane, from: pane.accountSwitch?.from, notify: false)
            }
        }
        return steps
    }

    func account(named name: String) throws -> ClaudeAccount {
        guard let account = claudeAccounts.account(named: name) else { throw RPCError.notFound("no account named \(name)") }
        return account
    }

    /// `--account NAME|auto` of `workspace.create` / `pane.split`.
    func resolveAccountParam(_ raw: String?) throws -> ClaudeAccount? {
        guard let raw else { return nil }
        if raw.lowercased() == ClaudeAccounts.automatic {
            guard !claudeAccounts.accounts.isEmpty else { throw RPCError.invalidParams("no accounts (cmds accounts add NAME DIR)") }
            guard let account = ClaudeAccounts.firstAvailable(in: claudeAccounts.accounts) else {
                throw RPCError.invalidParams("every account has hit its limit")
            }
            return account
        }
        return try account(named: raw)
    }

    /// The account of a pane's Claude Code: the one it was given or reported, else the account using the default
    /// config directory (a plain `claude`).
    func currentAccount(of pane: Pane) -> String? {
        pane.claudeAccount ?? ClaudeAccounts.account(forConfigDir: nil, in: claudeAccounts.accounts)?.name
    }

    // MARK: Learning a pane's account (agent.report)

    /// `configDir` as reported by `cmds hook claude-status` (its `CLAUDE_CONFIG_DIR`; "" = not set). Local panes only.
    func noteClaudeConfigDir(_ pane: Pane, configDir: String?) {
        guard let configDir, pane.ssh == nil else { return }
        let name = ClaudeAccounts.account(forConfigDir: configDir, in: claudeAccounts.accounts)?.name
        guard name != pane.claudeAccount else { return }
        pane.claudeAccount = name
        emit(.pane(workspaceID: pane.workspaceID, paneID: pane.id))
        scheduleSave()
    }

    /// Fills in the account of a Claude Code session remembered in a local pane (resuming it uses the same account).
    func applyAccount(to session: inout AgentSession, in pane: Pane) {
        guard session.agent == .claude, pane.ssh == nil else { return }
        if let name = pane.claudeAccount, let account = claudeAccounts.account(named: name) {
            session.account = account.name
            session.configDir = ClaudeAccounts.expandedPath(account.configDir)
        } else {
            session.account = nil
            session.configDir = nil
        }
    }

    // MARK: Detecting limits

    /// From the metadata scan: the screens of local panes running Claude Code.
    func scanClaudeLimits(now: Date = Date()) {
        for pane in workspaces.flatMap(\.orderedPanes) where pane.kind == .terminal && pane.ssh == nil && !pane.isClosing {
            guard pane.agentUsage?.agent == .claude || (pane.claudeAccount != nil && pane.agentActivity != .none),
                  let terminal = pane.terminal,
                  let hit = ClaudeLimitDetector.detect(screen: terminal.visibleText(), now: now) else { continue }
            handleLimitHit(pane, hit, key: "screen|" + hit.line, now: now)
        }
    }

    /// From `agent.report`: a status-line window at 100 %.
    func noteStatusLineLimits(_ pane: Pane, usage: AgentUsage, now: Date = Date()) {
        guard usage.agent == .claude, pane.ssh == nil, let hit = ClaudeLimitDetector.hit(fromLimits: usage.limits, now: now) else { return }
        handleLimitHit(pane, hit, key: "status|\(currentAccount(of: pane) ?? "")|\(hit.resetsAt?.timeIntervalSince1970 ?? 0)", now: now)
    }

    private func handleLimitHit(_ pane: Pane, _ hit: ClaudeLimitHit, key: String, now: Date) {
        pane.seenLimitLines = pane.seenLimitLines.filter { now.timeIntervalSince($0.value) < Self.limitLineMemory }
        guard pane.seenLimitLines[key] == nil else { return }
        pane.seenLimitLines[key] = now
        guard !claudeAccounts.accounts.isEmpty, pane.accountSwitch?.isInProgress != true else { return }
        let from = currentAccount(of: pane)
        if let from, let index = claudeAccounts.accounts.firstIndex(where: { $0.name == from }) {
            claudeAccounts.accounts[index].limit = ClaudeAccounts.merge(claudeAccounts.accounts[index].limit, hit.limit(now: now), now: now)
            saveClaudeAccounts()
        }
        offerAccountSwitch(pane, from: from, now: now)
    }

    /// Offers (or, with `autoSwitch`, starts) moving the pane's session to the next free account. `notify` false:
    /// only refreshes the offer (after sharing, or when the chosen account is no longer free).
    func offerAccountSwitch(_ pane: Pane, from: String?, notify: Bool = true, now: Date = Date()) {
        let target = ClaudeAccounts.next(after: from, in: claudeAccounts.accounts, now: now)
        let session = switchableSession(pane)
        let problem = switchProblem(pane, session: session, target: target)
        var change = AccountSwitch(from: from, to: target?.name, session: session, phase: .offered(problem: problem))
        let fromName = from ?? "Claude Code"
        if problem == nil, notify, claudeAccounts.autoSwitch, let target {
            change.phase = .waitingForIdle
            change.automatic = true
            pane.accountSwitch = change
            updateResumeBanner(pane)
            startAccountSwitchTimer()
            raiseAttention(pane: pane, title: String(localized: "Claude account limit"),
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
        raiseAttention(pane: pane, title: String(localized: "Claude account limit"), body: body,
                       category: problem == nil ? Self.accountNotificationCategory : nil)
    }

    /// The Claude Code session to continue: the running one, else one offered for resuming.
    private func switchableSession(_ pane: Pane) -> AgentSession? {
        if let session = pane.accountSwitch?.session { return session }
        if let session = pane.agentSession, session.agent == .claude { return session }
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
        let from = pane.accountSwitch?.from ?? currentAccount(of: pane)
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

    /// Dismiss / Cancel: nothing more is sent to the pane.
    func dismissAccountSwitch(_ pane: Pane) {
        guard pane.accountSwitch != nil else { return }
        pane.accountSwitch = nil
        updateResumeBanner(pane)
    }

    private func startAccountSwitchTimer() {
        guard accountSwitchTimer == nil else { return }
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.accountSwitchTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        accountSwitchTimer = timer
    }

    private func accountSwitchTick(now: Date = Date()) {
        var active = false
        for pane in workspaces.flatMap(\.orderedPanes) {
            guard var change = pane.accountSwitch, change.isInProgress else { continue }
            active = true
            guard !pane.isClosing, let terminal = pane.terminal, let group = terminal.foregroundProcessGroupID else { continue }
            let foreground = PaneProcessProbe.classify(pid: group)
            if foreground == .shell, !PaneProcessProbe.agentOnTerminal(of: group) {
                finishAccountSwitch(pane, change, now: now)
                continue
            }
            switch change.phase {
            case .waitingForIdle:
                // Never mid-turn: Claude Code in the foreground, not working, no subagent running, screen settled.
                let screen = terminal.visibleText()
                if screen != change.screen {
                    change.screen = screen
                    change.screenSince = now
                }
                let settled = now.timeIntervalSince(change.screenSince ?? now) >= Self.accountSwitchIdleTime
                let subagentRunning = pane.subagents.contains { $0.info.state == .running }
                if foreground == .agent, pane.agentActivity != .busy, !subagentRunning, settled {
                    terminal.sendText("\u{3}")
                    change.phase = .quitting
                    change.interrupts = 1
                    change.lastInterruptAt = now
                    pane.accountSwitch = change
                    updateResumeBanner(pane)
                    continue
                }
            case .quitting:
                // Claude Code quits on a second Ctrl-C; a first one may only clear a typed draft.
                let since = now.timeIntervalSince(change.lastInterruptAt ?? now)
                let due = change.interrupts < 2 ? since >= 0.4 : since >= 2.5
                if foreground == .agent, due, change.interrupts < 4 {
                    terminal.sendText("\u{3}")
                    change.interrupts += 1
                    change.lastInterruptAt = now
                } else if change.interrupts >= 4, since >= 5 {
                    change.phase = .offered(problem: .didNotQuit)
                    pane.accountSwitch = change
                    updateResumeBanner(pane)
                    raiseAttention(pane: pane, title: String(localized: "Claude account limit"), body: AccountSwitchProblem.didNotQuit.localized)
                    continue
                }
            case .offered:
                break
            }
            pane.accountSwitch = change
        }
        if !active {
            accountSwitchTimer?.invalidate()
            accountSwitchTimer = nil
        }
    }

    /// Claude Code has exited: hand the session to the resume machinery under the new account.
    private func finishAccountSwitch(_ pane: Pane, _ change: AccountSwitch, now: Date) {
        var failed = change
        guard let name = change.to, let target = claudeAccounts.account(named: name) else {
            failed.phase = .offered(problem: .noOtherAccount)
            pane.accountSwitch = failed
            return updateResumeBanner(pane)
        }
        guard var session = change.session else {
            failed.phase = .offered(problem: .noSession)
            pane.accountSwitch = failed
            return updateResumeBanner(pane)
        }
        session.account = target.name
        session.configDir = ClaudeAccounts.expandedPath(target.configDir)
        session.lastSeen = now
        guard AgentResume.command(for: session) != nil else {
            failed.phase = .offered(problem: .noSession)
            pane.accountSwitch = failed
            return updateResumeBanner(pane)
        }
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
        let from = change.from ?? "Claude Code"
        raiseAttention(pane: pane, title: String(localized: "Claude account switched"),
                       body: String(localized: "Continuing the session with “\(target.name)” (was “\(from)”)."))
    }

    // MARK: Banner

    /// Shows the pane's account banner; false when it has none (the resume banner may show instead).
    func showAccountBanner(_ pane: Pane) -> Bool {
        guard let change = pane.accountSwitch else { return false }
        let from = change.from ?? "Claude Code"
        let reset = change.from.flatMap { claudeAccounts.account(named: $0)?.limit }.map(Self.localizedReset)
        let lead = reset.map { String(localized: "“\(from)” hit its limit (\($0)).") } ?? String(localized: "“\(from)” hit its limit.")
        let banner: AccountSwitchBannerView
        switch change.phase {
        case .offered(let problem?):
            banner = AccountSwitchBannerView(state: .problem(text: "\(lead) \(problem.localized)",
                                                             canShare: { if case .notShared = problem { return true }; return false }()))
        case .offered(nil):
            banner = AccountSwitchBannerView(state: .offered(text: lead, target: change.to ?? ""))
        case .waitingForIdle:
            banner = AccountSwitchBannerView(state: .switching(text: String(localized: "Switching to “\(change.to ?? "")” once Claude Code is idle…")))
        case .quitting:
            banner = AccountSwitchBannerView(state: .switching(text: String(localized: "Switching to “\(change.to ?? "")”: quitting Claude Code…")))
        }
        banner.onSwitch = { [weak self, weak pane] in
            guard let self, let pane else { return }
            // The offered account may have hit its limit meanwhile: then the offer is worked out again.
            if (try? self.requestAccountSwitch(paneID: pane.id, to: pane.accountSwitch?.to)) == nil {
                self.offerAccountSwitch(pane, from: pane.accountSwitch?.from, notify: false)
            }
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
