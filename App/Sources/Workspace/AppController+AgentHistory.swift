import AppKit
import CmdsCore

/// Recent agent sessions (docs/guide/ai-agents.md "Recent sessions"): `agentHistory` keeps every session
/// `rememberAgentSession` saw, also after the agent exits or its pane closes. Opening one shows the pane holding it;
/// otherwise it is resumed in a new workspace (its directory, Claude account, SSH host) through the pane's offer and
/// the resume queue, so the command is typed only at that new shell's settled prompt. Nothing is typed into an
/// existing pane.
extension AppController {
    private static var agentHistorySaveBlocked = false

    static func loadAgentHistory() -> AgentSessionHistory {
        let loaded = AgentSessionHistoryStore.load(from: AgentSessionHistoryStore.url())
        if let error = loaded.error {
            if let moved = loaded.movedAside {
                NSLog("cmds: could not read the agent session history (\(error)); moved it to \(moved.path)")
            } else {
                NSLog("cmds: could not read the agent session history (\(error)); not saving it this run")
                agentHistorySaveBlocked = true
            }
        }
        return loaded.history
    }

    /// With the session (`saveSession`), so usage updates do not write the file each time.
    func saveAgentHistoryIfNeeded() {
        guard agentHistoryDirty, !Self.agentHistorySaveBlocked else { return }
        agentHistoryDirty = false
        do {
            try AgentSessionHistoryStore.save(agentHistory, to: AgentSessionHistoryStore.url())
        } catch {
            NSLog("cmds: failed to save the agent session history: \(error)")
        }
    }

    func clearAgentHistory() {
        agentHistory.removeAll()
        agentHistoryDirty = true
        scheduleSave()
    }

    /// The terminal pane holding `session`: running it, offering it or remembering it (newest focus first).
    func paneHolding(_ session: AgentSession) -> Pane? {
        let panes = workspaces.flatMap(\.orderedPanes).filter { $0.kind == .terminal && !$0.isClosing }
        func holds(_ pane: Pane) -> Bool {
            let host = pane.ssh?.launch.host
            if let usage = pane.agentUsage, usage.agent == session.agent, usage.sessionID == session.sessionID,
               host == session.host { return true }
            return [pane.resumeOffer, pane.agentSession].contains { $0.map { AgentSessionHistory.sameSession($0, session) } ?? false }
        }
        return panes.filter(holds).max { $0.focusedAt < $1.focusedAt }
    }

    /// `agent.history`: the newest sessions with the pane holding each.
    func agentHistoryList(limit: Int?) -> [AgentHistoryEntry] {
        let sessions = agentHistory.recent(limit ?? AgentSessionHistory.capacity)
        return sessions.map { session in
            let pane = paneHolding(session)
            return AgentHistoryEntry(session: session, pane: pane?.id, state: pane.map { historyState(of: $0) },
                                     command: AgentResume.command(for: session))
        }
    }

    private func historyState(of pane: Pane) -> AgentSessionState {
        if pane.resumeOffer != nil { return pane.resumeRequestedAt == nil ? .offered : .waiting }
        if pane.agentUsage != nil { return .running }
        return pane.resumedSessionID == pane.agentSession?.sessionID ? .resumed : .remembered
    }

    /// File › Recent Agent Sessions: focuses the pane holding the session (queuing its offer, if it has one), else
    /// resumes it in a new, selected workspace. Returns why it could not, nil when done.
    func openRecentAgentSession(_ remembered: AgentSession) -> String? {
        if let pane = paneHolding(remembered) {
            try? focusPane(id: pane.id)
            if pane.resumeOffer != nil { _ = requestResume(pane) }
            return nil
        }
        var session = remembered
        // The account it ran under (its current config directory); a removed account keeps the remembered one.
        let account = session.agent == .claude && session.host == nil ? session.account.flatMap(claudeAccounts.account(named:)) : nil
        if let account { session.configDir = ClaudeAccounts.expandedPath(account.configDir) }
        guard AgentResume.command(for: session) != nil else { return String(localized: "This session cannot be resumed.") }
        let pane: Pane
        if let host = session.host {
            let launch: SSHLaunch
            do {
                launch = try (try? SSHLaunch(host: host, remoteCwd: session.cwd)) ?? SSHLaunch(host: host)
            } catch {
                return String(localized: "The SSH host \(host) cannot be used.")
            }
            guard let info = try? createSSHWorkspace(launch), let created = info.panes.first.flatMap({ self.pane(id: $0.id) }) else {
                return String(localized: "Could not connect to \(host).")
            }
            pane = created
        } else {
            var directory: String?
            if let cwd = session.cwd {
                let expanded = (cwd as NSString).expandingTildeInPath
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
                    return String(localized: "The folder \(cwd) no longer exists.")
                }
                directory = expanded
            }
            let info = createWorkspace(cwd: directory, account: account)
            guard let created = info.panes.first.flatMap({ self.pane(id: $0.id) }) else { return nil }
            pane = created
        }
        // A fresh shell: the offer is queued at once and typed only once its prompt has settled.
        pane.resumeOffer = session
        _ = requestResume(pane)
        return nil
    }
}
