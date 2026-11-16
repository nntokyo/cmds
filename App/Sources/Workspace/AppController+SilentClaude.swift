import AppKit
import CmdsCore

/// A Claude Code that runs in a pane but does not report to cmds (#360): its config folder's `settings.json` has no
/// `cmds hook claude-status` status line, typically a `~/.claude` made again (signing in afresh) under a plain
/// `claude`. cmds then knows no session, limit or account for the pane, and a session it remembered there from before
/// is not the one running. Seen from the process itself (`PaneProcessProbe.claudeProcess`: started over
/// `silentAfter` ago, no status line report since), this:
/// - drops the pane's remembered session when the process started after it was last seen, and takes the pane's account
///   from the process's `CLAUDE_CONFIG_DIR`;
/// - says why in the account switch (`AccountSwitchProblem.notReporting`) instead of switching a stale session;
/// - offers to set the folder up (status line and hooks, `ClaudeAccountSetup`; added as an account when it is none),
///   once per folder and run, when the user has Claude accounts. Claude Code reads the new settings as it runs.
extension AppController {
    /// Claude Code reports at its first screen; one silent for this long does not report.
    static let silentClaudeAfter: TimeInterval = 45
    private static var silentClaudeCheckedAt: Date = .distantPast
    private static var silentClaudeOffered: Set<String> = []
    private static var silentClaudeAlertShown = false

    struct SilentClaude {
        var process: PaneProcessProbe.ClaudeProcess
        /// The folder it uses, expanded (`~/.claude` without `CLAUDE_CONFIG_DIR`).
        var configDir: String
    }

    /// The pane's Claude Code when it runs and does not report. `foregroundOnly`: look at the foreground process only
    /// (the periodic check; a plain `claude` leads its process group).
    func silentClaude(in pane: Pane, foregroundOnly: Bool = false, now: Date = Date()) -> SilentClaude? {
        guard pane.kind == .terminal, pane.ssh == nil, !pane.isClosing, pane.agentUsage?.agent != .claude,
              let group = pane.terminal?.foregroundProcessGroupID,
              let process = PaneProcessProbe.claudeProcess(onTerminalOf: group, foregroundOnly: foregroundOnly),
              now.timeIntervalSince(process.startedAt) >= Self.silentClaudeAfter else { return nil }
        let dir = ClaudeAccounts.expandedPath(process.configDir ?? ClaudeAccounts.defaultConfigDir)
        return SilentClaude(process: process, configDir: dir)
    }

    /// From each agent scan, at most every 30 seconds.
    func checkSilentClaudes(now: Date = Date()) {
        guard now.timeIntervalSince(Self.silentClaudeCheckedAt) >= 30 else { return }
        Self.silentClaudeCheckedAt = now
        var offer: (pane: Pane, silent: SilentClaude)?
        for pane in workspaces.flatMap(\.orderedPanes) {
            guard let silent = silentClaude(in: pane, foregroundOnly: true, now: now) else { continue }
            forgetStaleSession(pane, silent)
            if offer == nil, !Self.silentClaudeOffered.contains(silent.configDir), needsSetUp(silent.configDir) {
                offer = (pane, silent)
            }
        }
        if let offer { offerSilentClaudeSetUp(offer.pane, offer.silent) }
    }

    /// The session remembered for the pane is from before this Claude Code started: not the one running.
    private func forgetStaleSession(_ pane: Pane, _ silent: SilentClaude) {
        let account = ClaudeAccounts.account(forConfigDir: silent.process.configDir, in: claudeAccounts.accounts)?.name
        if pane.claudeAccount != account, pane.accountSwitch?.isInProgress != true {
            pane.claudeAccount = account
            emit(.pane(workspaceID: pane.workspaceID, paneID: pane.id))
            scheduleSave()
        }
        guard let session = pane.agentSession, session.agent == .claude, pane.resumeOffer == nil,
              session.lastSeen < silent.process.startedAt else { return }
        forgetAgentSession(pane)
    }

    /// The folder's settings lack cmds' status line, and Set Up can add it (a status line of the user's own is left
    /// to the user).
    private func needsSetUp(_ configDir: String) -> Bool {
        guard let state = ClaudeAccountSetup.state(of: ClaudeAccount(name: "_", configDir: configDir)) else { return false }
        return state.statusLine == .missing && state.canAdd
    }

    private func offerSilentClaudeSetUp(_ pane: Pane, _ silent: SilentClaude) {
        guard !claudeAccounts.accounts.isEmpty, CmdsEnv.supportDirectoryOverride() == nil, !Self.silentClaudeAlertShown else { return }
        Self.silentClaudeOffered.insert(silent.configDir)
        let folder = (silent.configDir as NSString).abbreviatingWithTildeInPath
        let existing = ClaudeAccounts.account(forConfigDir: silent.configDir, in: claudeAccounts.accounts)
        let name = existing?.name ?? ClaudeAccounts.suggestedName(forConfigDir: silent.configDir,
                                                                  taken: claudeAccounts.accounts.map(\.name))
        let place = workspace(id: pane.workspaceID).map { $0.displayTitle } ?? pane.id
        let alert = NSAlert()
        alert.messageText = String(localized: "Claude Code in “\(place)” does not report to cmds")
        var text = String(localized: """
            It uses \(folder), whose settings.json has no cmds status line (the folder was probably made again). \
            Without it cmds sees no session, limit or account there and cannot move the session to another account. \
            Set it up? The status line and hooks are added to settings.json (a copy is kept); Claude Code picks them up \
            as it runs.
            """)
        if existing == nil {
            text += " " + String(localized: "The folder is also added to your Claude accounts as “\(name)”.")
        }
        alert.informativeText = text
        alert.addButton(withTitle: String(localized: "Set Up for cmds"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        Self.silentClaudeAlertShown = true
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            Self.silentClaudeAlertShown = false
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                if existing == nil { try self.addAccount(name: name, configDir: folder) }
                try self.setUpAccount(name: name)
            } catch {
                let failed = NSAlert()
                failed.messageText = String(localized: "\(folder) could not be set up")
                failed.informativeText = (error as? RPCError)?.message ?? "\(error)"
                failed.runModal()
            }
        }
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }
}
