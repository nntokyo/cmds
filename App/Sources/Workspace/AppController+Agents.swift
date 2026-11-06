import Foundation
import CmdsCore

/// Coding agents in terminal panes: usage reports (`agent.report`, `agent.claude_status`), Claude Code hooks,
/// metadata scans and the agent state derived from them.
extension AppController {
    /// Account limits per agent kind, without windows that have reset since.
    func activeAgentLimits(now: Date = Date()) -> [AgentLimits] {
        agentLimitsByKind.values.compactMap { $0.active(at: now) }.sorted { $0.agent < $1.agent }
    }

    /// Result of the socket method `agent.list`.
    func agentList() -> AgentList {
        let panes = workspaces.flatMap { workspace in
            workspace.agentPanes.compactMap { pane in
                pane.agentUsage.map { AgentPaneUsage(workspace: workspace.id, pane: pane.id, usage: $0) }
            }
        }
        return AgentList(panes: panes, limits: activeAgentLimits())
    }

    /// `agent.report`: usage of the agent in a terminal pane (Claude Code's status line via `cmds hook claude-status`).
    /// With `pid` (the agent process) the usage is dropped as soon as that process exits. `configDir`: Claude Code's
    /// `CLAUDE_CONFIG_DIR` ("" = not set), which names the pane's account (AppController+Accounts).
    func reportAgentUsage(paneID: String?, usage: AgentUsage, pid: Int32?, configDir: String? = nil) throws {
        let pane = try resolvePane(paneID)
        guard pane.kind == .terminal else { throw RPCError.invalidParams("pane \(pane.id) is not a terminal") }
        let now = Date()
        var usage = usage
        usage.updatedAt = now
        usage.stale = nil
        if !usage.limits.isEmpty {
            agentLimitsByKind[usage.agent] = AgentLimits(agent: usage.agent, limits: usage.limits, plan: usage.plan, updatedAt: now)
        }
        var process: AgentProcessRef?
        if let pid {
            if case .report(let known?)? = pane.agentSource, known.pid == pid { process = known }
            else { process = AgentProcessRef(pid: pid) }
        }
        let appeared = pane.agentUsage?.agent != usage.agent
        if let previous = pane.agentUsage, Self.reportShowsWork(previous, usage) { pane.agentSignals.reportChangedAt = now }
        pane.agentUsage = usage
        pane.agentSource = .report(process: process)
        pane.agentSignals.hasUsage = true
        if usage.agent == .claude { noteClaudeConfigDir(pane, configDir: configDir) }
        rememberAgentSession(pane, usage: usage)
        noteStatusLineLimits(pane, usage: usage, now: now)
        updateAgentActivity(pane, now: now, emitChange: !appeared)
        if appeared { emit(.pane(workspaceID: pane.workspaceID, paneID: pane.id)) }
        scheduleAgentRefresh()
    }

    /// The figures moved between two status-line reports: the agent called the model (reports are also sent when
    /// nothing happens, e.g. on a refresh interval).
    static func reportShowsWork(_ old: AgentUsage, _ new: AgentUsage) -> Bool {
        old.costUSD != new.costUSD || old.contextTokens != new.contextTokens || old.outputTokens != new.outputTokens
            || old.contextUsedPercent != new.contextUsedPercent || old.apiDurationMs != new.apiDurationMs
    }

    /// `agent.claude_hook`: a Claude Code hook payload (`cmds hook claude`, or `cmds-remote.sh hook claude` on a
    /// server, forwarded as is). The transcript is never read (it may be a path on another machine); `Stop` uses
    /// `last_assistant_message`. Notification / Stop notify; every event updates the pane's agent state.
    func claudeHook(paneID: String?, input: JSONValue) throws {
        let pane = try resolvePane(paneID)
        let data = try JSONEncoder().encode(input)
        guard let event = ClaudeHook.event(fromHookInput: data, readTranscript: false) else { return }
        let now = Date()
        if case .subagent(let agent) = event {
            // Subagents (AppController+Subagents): a local pane's transcript is followed, only if it has the shape of
            // a Claude Code subagent transcript; the pane's own state is left alone.
            handleSubagentHook(pane: pane, agent: agent, now: now)
            return
        }
        pane.agentSignals.hookBusyFollowsSpinner = false
        switch event {
        case .needsInput: pane.agentSignals.hook = .needsInput
        case .finished: pane.agentSignals.hook = .finished
        case .working:
            pane.agentSignals.hook = .busy
            pane.agentSignals.workingHookAt = now
        case .ended:
            pane.agentSignals.hook = nil
            pane.agentSignals.endedAt = now
            // Claude Code exited: its status-line usage goes with it (like a watched process exiting).
            if pane.agentUsage?.agent == .claude {
                pane.agentUsage = nil
                pane.agentSource = nil
                pane.agentSignals.hasUsage = false
                forgetAgentSession(pane)
                scheduleAgentRefresh()
            }
            dropSubagents(of: pane)
        case .subagent:
            return // handled above
        }
        noteHook(pane, working: event == .working, notification: event.notification, now: now)
    }

    /// `agent.codex_hook`: a Codex hook payload as `cmds hook codex` forwards it. Codex runs hooks with its own
    /// environment, the shared app-server daemon's for most TUIs, so `paneID` (its `CMDS_PANE_ID`) is only a hint:
    /// the pane is the one running that Codex session (`CodexHook.targetPane`). Events no pane can be told for are
    /// dropped. PermissionRequest / Stop notify; every event updates the pane's agent state.
    func codexHook(paneID: String?, input: JSONValue) throws {
        guard let payload = CodexHook.payload(fromForwarded: input) else { return }
        let panes = codexPaneDirectories.map { id, cwd in
            CodexHook.Pane(paneID: id, cwd: cwd.isEmpty ? nil : cwd,
                           sessionID: self.pane(id: id).flatMap { $0.agentUsage?.agent == .codex ? $0.agentUsage?.sessionID : nil })
        }
        guard let target = CodexHook.targetPane(sessionID: payload.sessionID, cwd: payload.cwd, envPane: paneID, panes: panes),
              let pane = pane(id: target) else { return }
        let now = Date()
        pane.agentSignals.hookBusyFollowsSpinner = true
        switch payload.event {
        case .needsInput: pane.agentSignals.hook = .needsInput
        case .finished, .interrupted: pane.agentSignals.hook = .finished
        case .working:
            pane.agentSignals.hook = .busy
            pane.agentSignals.workingHookAt = now
        }
        noteHook(pane, working: payload.event == .working, notification: payload.event.notification, now: now)
    }

    /// After a hook changed the pane's hook state: working again clears an older notification; a notification
    /// raises attention.
    private func noteHook(_ pane: Pane, working: Bool, notification: ClaudeHook.Notification?, now: Date) {
        pane.agentSignals.hookAt = now
        if working { clearNotification(of: pane, before: now) }
        if let notification {
            updateAgentActivity(pane, now: now, emitChange: false)
            raiseAttention(pane: pane, title: notification.title, body: notification.body)
        } else {
            updateAgentActivity(pane, now: now)
        }
    }

    /// Re-derives the pane's agent state from its signals. Working again after a notification clears that
    /// notification (attention and sidebar text). Emits a pane change only when the state changed.
    func updateAgentActivity(_ pane: Pane, now: Date = Date(), emitChange: Bool = true) {
        let activity = pane.agentSignals.activity(at: now)
        if activity == .busy, let busyAt = pane.agentSignals.lastBusyAt {
            // Evidence from right after the notification still belongs to the turn that raised it.
            clearNotification(of: pane, before: busyAt.addingTimeInterval(-AgentSignals.reportGrace))
        }
        guard activity != pane.agentActivity else { return }
        pane.agentActivity = activity
        if activity != .none { pane.agentEverSeen = true }
        if emitChange { emit(.pane(workspaceID: pane.workspaceID, paneID: pane.id)) }
    }

    /// The user typed in the pane: its notification has been seen (attention is already cleared by focusing).
    func paneDidReceiveKeyInput(_ pane: Pane) {
        // Not one that arrived while typing (the user may not have read it yet).
        clearNotification(of: pane, before: Date().addingTimeInterval(-1))
    }

    /// Clears the pane's attention and the workspace's notification text when they came from this pane before `date`.
    func clearNotification(of pane: Pane, before date: Date) {
        guard let workspace = workspace(id: pane.workspaceID) else { return }
        var changed = false
        if pane.attention, (pane.attentionDate ?? .distantPast) < date {
            clearAttention(pane)
            changed = true
        }
        if workspace.notificationPaneID == pane.id, (workspace.notificationDate ?? .distantPast) < date {
            workspace.clearNotificationText()
            changed = true
        }
        if changed { emit(.workspace(id: workspace.id)) }
    }

    /// Sidebar "Clear Notification": drops the workspace's notification text and the attention of all its panes.
    func clearNotification(workspaceID: String?) throws {
        let workspace = try resolveWorkspace(workspaceID)
        for pane in workspace.panes.values where pane.attention { clearAttention(pane) }
        workspace.clearNotificationText()
        emit(.workspace(id: workspace.id))
    }

    /// `agent.claude_status`: Claude Code's status-line JSON forwarded as is (`cmds-remote.sh hook claude-status`).
    /// No process to watch: the usage goes when the SSH connection drops, else after `unwatchedAgentTimeout`.
    func claudeStatus(paneID: String?, input: JSONValue) throws {
        let data = try JSONEncoder().encode(input)
        guard let usage = ClaudeStatusLine.usage(fromJSON: data) else {
            throw RPCError.invalidParams("input is not Claude Code status-line JSON")
        }
        try reportAgentUsage(paneID: paneID, usage: usage, pid: nil)
    }

    /// Codex's used-up windows changed (`AgentLimits.exhaustedReset`).
    static let codexLimitsDidChange = Notification.Name("cmdsCodexLimitsDidChange")

    /// Applies a metadata scan: drops usage of agents that exited, marks idle ones stale, takes Codex usage from its
    /// session files (a pane reporting through `agent.report` keeps that) and the newest Codex limits.
    /// The caller sends the usage update (`applyResourceUsage`) right after.
    func applyAgentScan(_ codex: CodexWatchResult, now: Date = Date()) {
        if let limits = codex.limits, limits.updatedAt > (agentLimitsByKind[.codex]?.updatedAt ?? .distantPast) {
            let resetChanged = limits.exhaustedReset != agentLimitsByKind[.codex]?.exhaustedReset
            agentLimitsByKind[.codex] = limits
            // Schedules that follow Codex's limit (ScheduleRunner).
            if resetChanged { NotificationCenter.default.post(name: Self.codexLimitsDidChange, object: nil) }
        }
        codexPaneDirectories = Dictionary(uniqueKeysWithValues: codex.panes.map { ($0, codex.directories[$0] ?? "") })
        for workspace in workspaces {
            for pane in workspace.orderedPanes where pane.kind == .terminal {
                var usage = pane.agentUsage
                var source = pane.agentSource
                switch source {
                case .report(let process)?:
                    let exited = process.map { !$0.isAlive } ?? false
                    let gone = exited || (process == nil && now.timeIntervalSince(usage?.updatedAt ?? now) > Self.unwatchedAgentTimeout)
                    if gone { (usage, source) = (nil, nil) }
                    // Only a process seen exiting ends the session; an idle remote agent may still be running.
                    if exited {
                        forgetAgentSession(pane)
                        pane.agentSignals.endedAt = now
                        dropSubagents(of: pane)
                    }
                case .codexSession?:
                    if !codex.panes.contains(pane.id) {
                        (usage, source) = (nil, nil)
                        forgetAgentSession(pane)
                        pane.agentSignals.endedAt = now
                    }
                case nil:
                    break
                }
                if source == nil || source == .codexSession, let fresh = codex.usage[pane.id] {
                    usage = fresh
                    source = .codexSession
                    if fresh != pane.agentUsage {
                        rememberAgentSession(pane, usage: fresh)
                        // Codex wrote to its session file: it is working.
                        if let old = pane.agentUsage, fresh.updatedAt > old.updatedAt { pane.agentSignals.reportChangedAt = fresh.updatedAt }
                    }
                }
                if var current = usage {
                    current.stale = now.timeIntervalSince(current.updatedAt) > Self.agentStaleAfter ? true : nil
                    usage = current
                }
                let appearedOrGone = (usage?.agent) != (pane.agentUsage?.agent)
                pane.agentSource = source
                pane.agentSignals.hasUsage = usage != nil
                // Also on every scan: spinners stop, busy times out.
                updateAgentActivity(pane, now: now, emitChange: !appearedOrGone)
                guard usage != pane.agentUsage else { continue }
                pane.agentUsage = usage
                if appearedOrGone { emit(.pane(workspaceID: workspace.id, paneID: pane.id)) }
            }
        }
    }

    private static let agentRefreshDelay: TimeInterval = 0.25

    /// Reports arrive often; redraw usage labels (sidebar, phone) at most a few times a second.
    func scheduleAgentRefresh() {
        guard !agentRefreshScheduled else { return }
        agentRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.agentRefreshDelay) { [weak self] in
            MainActor.assumeIsolated {
                self?.agentRefreshScheduled = false
                self?.usageSubject.send()
            }
        }
    }
}
