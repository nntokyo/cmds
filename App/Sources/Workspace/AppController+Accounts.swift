import AppKit
import CmdsCore

/// Several Claude Code accounts of the user (docs/guide/ai-agents.md "Several Claude accounts").
///
/// - Accounts: names and config directories (`ClaudeAccountSettings`, saved in `claude-accounts.json` in the support
///   directory). A pane created with an account gets its `CLAUDE_CONFIG_DIR`; `cmds hook claude-status` reports the
///   `CLAUDE_CONFIG_DIR` Claude Code actually runs with, which names the pane's account.
/// - Limits: every metadata scan (2 s) reads the screen of local panes running Claude Code for a limit message
///   (`ClaudeLimitDetector`); status-line windows at 100 % count too. The account's reset time is recorded.
/// - Switching (AppController+AccountSwitch): offered in the pane (banner, notification with an action), or started
///   by itself with `autoSwitch`. Once Claude Code is idle at its prompt it gets Ctrl-C (twice, as Claude Code asks);
///   when the shell is back the session is handed to the resume machinery (AppController+AgentSessions) as
///   `env CLAUDE_CONFIG_DIR='<next>' claude --resume <id>`. Only when the transcript is reachable from the next
///   account (`ClaudeSessionSharing`), never mid-turn, never in SSH panes.
extension AppController {
    static let accountsDidChange = Notification.Name("cmdsClaudeAccountsDidChange")
    /// The same limit line in a pane is handled once in this time (a resumed session may show it again).
    static let limitLineMemory = ClaudeLimitDetector.sessionWindow
    /// JSON-RPC "internal error": sharing failed on the Mac, not because of the request.
    private static let internalErrorCode = -32603

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
            let panes = workspaces.flatMap(\.orderedPanes)
                .filter { $0.claudeAccount.map(account.hasName) ?? false }.map(\.id)
            return ClaudeAccountStatus(name: account.name, configDir: account.configDir,
                                       exists: ClaudeAccounts.configDirExists(account),
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
        // Panes no longer show (or save) an account cmds does not know (#44). Their shells keep the config directory
        // they were started with; `cmds hook claude-status` reports it again if the account is added back.
        for pane in workspaces.flatMap(\.orderedPanes) where pane.claudeAccount.map(account.hasName) ?? false {
            pane.claudeAccount = nil
            emit(.pane(workspaceID: pane.workspaceID, paneID: pane.id))
            scheduleSave()
        }
        saveClaudeAccounts()
    }

    func moveAccount(name: String, to index: Int) throws {
        let account = try account(named: name)
        if let problem = ClaudeAccounts.positionProblem(index, count: claudeAccounts.accounts.count) {
            throw RPCError.invalidParams(problem)
        }
        claudeAccounts.accounts.removeAll { $0.name == account.name }
        claudeAccounts.accounts.insert(account, at: index)
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

    /// `account.share` without `apply`: what sharing the session transcripts would do.
    func accountSharingPlan() -> [ClaudeSessionSharing.Step] {
        ClaudeSessionSharing.plan(claudeAccounts.accounts)
    }

    /// `account.share` with `apply`: shares the session transcripts (`ClaudeSessionSharing.apply`, which never deletes
    /// anything). Returns the steps it carried out.
    func shareAccountSessions() throws -> [ClaudeSessionSharing.Step] {
        let accounts = claudeAccounts.accounts
        let steps = ClaudeSessionSharing.plan(accounts)
        do {
            try ClaudeSessionSharing.apply(steps, accounts: accounts)
        } catch {
            NotificationCenter.default.post(name: Self.accountsDidChange, object: nil)
            throw RPCError(code: Self.internalErrorCode, message: "sharing sessions failed: \(error)")
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
}
