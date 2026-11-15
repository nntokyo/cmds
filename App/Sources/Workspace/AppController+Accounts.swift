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
    /// The same limit line of an account in a pane is handled once until its limit ends, and at least this long.
    static let limitLineMemory = ClaudeLimitDetector.sessionWindow
    /// JSON-RPC "internal error": sharing failed on the Mac, not because of the request.
    private static let internalErrorCode = -32603

    // MARK: Accounts (account.*)

    /// Set when `claude-accounts.json` could not be read and could not be moved aside: saving would overwrite it (#46).
    private static var claudeAccountsSaveBlocked = false

    /// The accounts in `claude-accounts.json`. A damaged file is moved aside (kept) and reported, and cmds starts
    /// without accounts; one that cannot be read stays in place and is never saved over this run (#46).
    static func loadClaudeAccounts() -> ClaudeAccountSettings {
        let loaded = ClaudeAccountStore.load(from: ClaudeAccountStore.url())
        if let error = loaded.error {
            if let moved = loaded.movedAside {
                NSLog("cmds: could not read Claude accounts (\(error)); moved them to \(moved.path)")
                showClaudeAccountsMovedAsideAlert(moved)
            } else {
                NSLog("cmds: could not read Claude accounts (\(error)); not saving them this run")
                claudeAccountsSaveBlocked = true
            }
        }
        return loaded.settings
    }

    private static func showClaudeAccountsMovedAsideAlert(_ moved: URL) {
        let name = moved.lastPathComponent
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = String(localized: "Claude accounts could not be read")
            alert.informativeText = String(localized: "The damaged file was kept as \(name) in the cmds support folder, and cmds started with an empty one.")
            alert.addButton(withTitle: String(localized: "OK"))
            if let window = AppController.shared.window, window.isVisible {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    func saveClaudeAccounts() {
        if Self.claudeAccountsSaveBlocked {
            NSLog("cmds: not saving Claude accounts: claude-accounts.json could not be read")
        } else {
            do {
                try ClaudeAccountStore.save(claudeAccounts, to: ClaudeAccountStore.url())
            } catch {
                NSLog("cmds: could not save Claude accounts: \(error)")
            }
        }
        NotificationCenter.default.post(name: Self.accountsDidChange, object: nil)
    }

    func accountList(now: Date = Date()) -> ClaudeAccountList {
        let accounts = claudeAccounts.accounts
        var signIns: [String: String] = [:]
        for account in accounts { signIns[account.name] = ClaudeAccounts.signIn(of: account) }
        let statuses = accounts.map { account -> ClaudeAccountStatus in
            let panes = workspaces.flatMap(\.orderedPanes)
                .filter { $0.claudeAccount.map(account.hasName) ?? false }.map(\.id)
            return ClaudeAccountStatus(name: account.name, configDir: account.configDir,
                                       exists: ClaudeAccounts.configDirExists(account),
                                       limit: account.isLimited(at: now) ? account.limit : nil,
                                       sessions: ClaudeSessionSharing.link(of: account, in: accounts), panes: panes,
                                       sameSignInAs: signIns[account.name].flatMap { id in
                                           accounts.first { !$0.hasName(account.name) && signIns[$0.name] == id }?.name
                                       },
                                       needsSetup: ClaudeAccountSetup.state(of: account).map { !$0.isComplete })
        }
        let missing = chromeHostMissing()
        return ClaudeAccountList(accounts: statuses, autoSwitch: claudeAccounts.autoSwitch,
                                 chromeHostMissing: missing.isEmpty ? nil : missing)
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

    /// The other accounts signed in to the same Claude account as `name` (they share its limit); none when `name` is
    /// not one of the user's accounts or is not signed in.
    func accountsSharingSignIn(with name: String?) -> [ClaudeAccount] {
        guard let name, let account = claudeAccounts.account(named: name) else { return [] }
        return ClaudeAccounts.sameSignIn(as: account, in: claudeAccounts.accounts)
    }

    /// Set Up (the sidebar's account menu, Settings › Claude Accounts, `account.setup`): adds cmds's status line and
    /// hooks to the account's `settings.json` when missing (`ClaudeAccountSetup.apply`; the previous file is kept).
    @discardableResult
    func setUpAccount(name: String) throws -> ClaudeAccountSetup.Result {
        let account = try account(named: name)
        do {
            let result = try ClaudeAccountSetup.apply(to: account, in: claudeAccounts.accounts)
            NotificationCenter.default.post(name: Self.accountsDidChange, object: nil)
            return result
        } catch let error as ClaudeAccountSetup.SetupError {
            throw RPCError.invalidParams("account \(account.name): \(error.description)")
        } catch {
            throw RPCError(code: Self.internalErrorCode, message: "setting up \(account.name) failed: \(error)")
        }
    }

    /// The shell command that signs a config directory in (`claude auth login`), run in a workspace under the account.
    static let signInCommand = "claude auth login"

    /// Sign In (the sidebar's account menu, Settings › Claude Accounts, `account.login`): a new workspace under the
    /// account whose shell runs `claude auth login` and stays open. Claude Code creates the directory when missing.
    @discardableResult
    func signInToAccount(name: String, select: Bool = true) throws -> WorkspaceInfo {
        let account = try account(named: name)
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { AgentResume.quotedPath($0) != nil ? $0 : nil } ?? "/bin/zsh"
        let command = "\(shell) -lic '\(Self.signInCommand); exec \(shell) -l'"
        return createWorkspace(title: String(localized: "Sign in: \(account.name)"), command: command, account: account, select: select)
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
        // Claude Code runs here: a good moment to see that Claude in Chrome can reach it (throttled).
        checkChromeHostSoon()
        // An account signed in while cmds runs gets cmds' MCP server too (MCPAutoRegistration, throttled).
        MCPAutoRegistration.runSoon()
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
                  let terminal = pane.terminal else { continue }
            let screen = terminal.visibleText()
            if carriesLimitLines(pane, screen: screen) { continue }
            guard let hit = ClaudeLimitDetector.detect(screen: screen, now: now, ignoring: pane.carriedLimitLines) else { continue }
            handleLimitHit(pane, hit, key: limitKey(.screen, account: currentAccount(of: pane)) + hit.line, now: now)
        }
    }

    /// After a switch: until Claude Code works on a prompt under the new account, every limit line on the screen is the
    /// resumed transcript's (true: nothing to detect yet). Later, carried lines are ignored while they stay on screen.
    private func carriesLimitLines(_ pane: Pane, screen: String) -> Bool {
        if let since = pane.holdsLimitLinesSince {
            // Working on a prompt: a limit line from now on can be the new account's (it may come back at once).
            if pane.agentSignals.workedSince(since) {
                pane.holdsLimitLinesSince = nil
            } else {
                pane.carriedLimitLines.formUnion(ClaudeLimitDetector.hitLines(screen: screen))
                return true
            }
        }
        if !pane.carriedLimitLines.isEmpty {
            pane.carriedLimitLines.formIntersection(ClaudeLimitDetector.hitLines(screen: screen))
        }
        return false
    }

    /// A switch to another account is done: the limit lines on the screen and the ones the previous account hit are
    /// carried, and so is every one shown until Claude Code works under the new account (`carriesLimitLines`).
    func carryLimitLines(_ pane: Pane, from account: String?, now: Date) {
        let prefix = limitKey(.screen, account: account)
        var lines = Set(pane.seenLimitLines.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
        if let terminal = pane.terminal { lines.formUnion(ClaudeLimitDetector.hitLines(screen: terminal.visibleText())) }
        pane.carriedLimitLines = lines
        pane.holdsLimitLinesSince = now
    }

    /// From `agent.report`: a status-line window at 100 %.
    func noteStatusLineLimits(_ pane: Pane, usage: AgentUsage, now: Date = Date()) {
        guard usage.agent == .claude, pane.ssh == nil, let hit = ClaudeLimitDetector.hit(fromLimits: usage.limits, now: now) else { return }
        handleLimitHit(pane, hit, key: limitKey(.statusLine, account: currentAccount(of: pane)) + "\(hit.resetsAt?.timeIntervalSince1970 ?? 0)",
                       now: now)
    }

    /// Where a limit was seen, for the keys of `Pane.seenLimitLines`.
    private enum LimitSource: String { case screen, statusLine = "status" }

    /// The start of a `Pane.seenLimitLines` key: the source and the account (`screen|work|`); the line or reset follows.
    private func limitKey(_ source: LimitSource, account: String?) -> String {
        "\(source.rawValue)|\(account ?? "")|"
    }

    private func handleLimitHit(_ pane: Pane, _ hit: ClaudeLimitHit, key: String, now: Date) {
        pane.seenLimitLines = pane.seenLimitLines.filter { $0.value > now }
        guard pane.seenLimitLines[key] == nil else { return }
        let limit = hit.limit(now: now)
        // At least the usage window: a line Claude Code keeps showing after the reset is not a new limit.
        pane.seenLimitLines[key] = max(limit.resetsAt, now.addingTimeInterval(Self.limitLineMemory))
        guard !claudeAccounts.accounts.isEmpty, pane.accountSwitch?.isInProgress != true else { return }
        let from = currentAccount(of: pane)
        if let from, let index = claudeAccounts.accounts.firstIndex(where: { $0.name == from }) {
            // Accounts signed in to the same Claude account have hit the same limit.
            let limited = [index] + accountsSharingSignIn(with: from).compactMap { other in
                claudeAccounts.accounts.firstIndex { $0.hasName(other.name) }
            }
            for index in limited {
                claudeAccounts.accounts[index].limit = ClaudeAccounts.merge(claudeAccounts.accounts[index].limit, limit, now: now)
            }
            saveClaudeAccounts()
            refreshOffers(to: from, except: pane, now: now)
        }
        offerAccountSwitch(pane, from: from, now: now)
    }

    /// `name` hit its limit: offers elsewhere to continue with it are worked out again (the next free account, or why
    /// there is none), so Continue never moves a session to an account that is limited.
    private func refreshOffers(to name: String, except pane: Pane, now: Date) {
        for other in workspaces.flatMap(\.orderedPanes) where other !== pane {
            guard let change = other.accountSwitch, !change.isInProgress, change.to == name else { continue }
            offerAccountSwitch(other, from: change.from, notify: false, now: now)
        }
    }
}
