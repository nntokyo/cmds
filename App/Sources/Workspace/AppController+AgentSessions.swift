import AppKit
import CmdsCore
import Darwin

/// View › Resume Agent Sessions on Launch. Kept in `UserDefaults` (`AgentResumeMode`); an isolated instance
/// (`CMDS_SUPPORT_DIR`) never touches the defaults of the app in use: it starts from `CMDS_AGENT_RESUME`
/// (`ask`/`always`/`never`, default ask) and keeps changes in memory.
@MainActor
enum AgentResumeSettings {
    static let defaultsKey = "AgentResumeMode"
    static let environmentKey = "CMDS_AGENT_RESUME"
    private static var isolatedMode: AgentResumeMode?

    static var mode: AgentResumeMode {
        get {
            if CmdsEnv.supportDirectoryOverride() != nil {
                if let isolatedMode { return isolatedMode }
                let raw = ProcessInfo.processInfo.environment[environmentKey]?.lowercased() ?? ""
                return AgentResumeMode(rawValue: raw) ?? .ask
            }
            return UserDefaults.standard.string(forKey: defaultsKey).flatMap(AgentResumeMode.init(rawValue:)) ?? .ask
        }
        set {
            if CmdsEnv.supportDirectoryOverride() != nil {
                isolatedMode = newValue
            } else {
                UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            }
        }
    }
}

/// Resuming AI agent sessions after a restart (docs/guide/ai-agents.md "Resuming sessions").
///
/// - Remembering: whenever a pane's agent reports usage with a session id (Claude Code status line, Codex session
///   file), the pane's `agentSession` is updated (cwd = the pane's directory when the session first appeared, host
///   for SSH panes). It is forgotten when the agent is seen to exit (its process ended); not when cmds quits.
/// - Offering: on launch each restored terminal pane with a saved session gets `resumeOffer` and a banner (mode
///   Ask), is queued right away (Always) or forgets it (Never). SSH panes also get an offer when their connection
///   drops while an agent ran.
/// - Resuming: a queued pane gets `AgentResume.command` typed into its own shell, once: when the shell is the
///   foreground process and its screen has settled (SSH panes: connected, and the remote prompt reported through
///   `remote.location` or a settled screen ending in a prompt character). Nothing is typed when the pane runs an agent.
extension AppController {
    // MARK: Remembering

    /// Called for each usage update of a pane's agent.
    func rememberAgentSession(_ pane: Pane, usage: AgentUsage) {
        guard pane.kind == .terminal, AgentResume.supports(usage.agent),
              let id = usage.sessionID, AgentResume.isValidSessionID(id) else { return }
        let host = pane.ssh?.launch.host
        let title = AgentResume.cleanTitle(pane.title)
        var record: AgentSession
        let isNew: Bool
        if var existing = pane.agentSession, existing.sessionID == id, existing.agent == usage.agent, existing.host == host {
            existing.lastSeen = max(existing.lastSeen, usage.updatedAt)
            existing.model = usage.model ?? existing.model
            existing.title = title ?? existing.title
            record = existing
            isNew = false
        } else {
            record = AgentSession(agent: usage.agent, sessionID: id, cwd: pane.workingDirectory, host: host, title: title,
                                  model: usage.model, lastSeen: usage.updatedAt)
            isNew = true
        }
        pane.agentSession = record
        // A live agent in the pane makes any offer moot (and must never get a resume command typed over it).
        if pane.resumeOffer != nil { clearResumeOffer(pane) }
        if isNew || record.lastSeen.timeIntervalSince(pane.agentSessionSavedAt ?? .distantPast) > 60 {
            pane.agentSessionSavedAt = record.lastSeen
            scheduleSave()
        }
    }

    /// The agent was seen to exit on its own: nothing to resume later.
    func forgetAgentSession(_ pane: Pane) {
        guard pane.agentSession != nil else { return }
        pane.agentSession = nil
        pane.agentSessionSavedAt = nil
        scheduleSave()
    }

    /// An SSH pane lost its connection while an agent ran: offer to resume after reconnecting.
    func offerResumeAfterDisconnect(_ pane: Pane) {
        guard let session = pane.agentSession, pane.resumeOffer == nil, AgentResume.command(for: session) != nil else { return }
        pane.resumeOffer = session
        if AgentResumeSettings.mode == .always { pane.resumeRequestedAt = Date() }
        updateResumeBanner(pane)
        startResumeTimerIfNeeded()
    }

    /// Session restore: applies the saved sessions of a workspace (pane indexes in reading order).
    func restoreAgentSessions(_ saved: [SessionState.PaneAgentSession]?, in workspace: Workspace,
                              mode: AgentResumeMode? = nil) {
        guard let saved, !saved.isEmpty else { return }
        let mode = mode ?? AgentResumeSettings.mode
        let panes = workspace.orderedPanes
        for entry in saved {
            guard let pane = panes[safe: entry.paneIndex], pane.kind == .terminal, pane.preview == nil,
                  entry.session.host == pane.ssh?.launch.host, AgentResume.command(for: entry.session) != nil else { continue }
            guard mode != .never else { continue }
            pane.agentSession = entry.session
            pane.agentSessionSavedAt = entry.session.lastSeen
            pane.resumeOffer = entry.session
            if mode == .always { pane.resumeRequestedAt = Date() }
        }
        // After all offers exist, so each banner counts the others (Resume All).
        panes.filter { $0.resumeOffer != nil }.forEach(updateResumeBanner)
        startResumeTimerIfNeeded()
    }

    /// The session to save for a pane: a pending offer (not resumed yet) or the session seen this run.
    func savedAgentSession(_ pane: Pane) -> AgentSession? {
        pane.resumeOffer ?? pane.agentSession
    }

    // MARK: Queries (agent.sessions)

    func agentSessionList(paneID: String?) throws -> AgentSessionList {
        let only = try paneID.map { try resolvePane($0).id }
        var entries: [AgentSessionEntry] = []
        for workspace in workspaces {
            for pane in workspace.orderedPanes where only == nil || pane.id == only {
                let state: AgentSessionState
                let session: AgentSession
                if let offer = pane.resumeOffer {
                    state = pane.resumeRequestedAt == nil ? .offered : .waiting
                    session = offer
                } else if let current = pane.agentSession {
                    state = pane.agentUsage != nil ? .running : (pane.resumedSessionID == current.sessionID ? .resumed : .remembered)
                    session = current
                } else {
                    continue
                }
                entries.append(AgentSessionEntry(workspace: workspace.id, pane: pane.id, state: state, session: session,
                                                 command: AgentResume.command(for: session)))
            }
        }
        return AgentSessionList(mode: AgentResumeSettings.mode, sessions: entries)
    }

    var pendingResumeCount: Int {
        workspaces.reduce(0) { $0 + $1.panes.values.filter { $0.resumeOffer != nil }.count }
    }

    // MARK: Resuming

    /// `agent.resume`: queues the offered session of `paneID` (default: focused pane), or of every pane with `all`.
    /// Panes without an offer are reported as skipped; nothing is ever typed into them.
    @discardableResult
    func resumeAgentSessions(paneID: String?, all: Bool) throws -> AgentResumeResult {
        var result = AgentResumeResult()
        let panes: [Pane]
        if all {
            panes = workspaces.flatMap(\.orderedPanes).filter { $0.resumeOffer != nil }
        } else {
            panes = [try resolvePane(paneID)]
        }
        for pane in panes {
            if let reason = requestResume(pane) {
                result.skipped.append(.init(pane: pane.id, reason: reason))
            } else {
                result.queued.append(pane.id)
            }
        }
        return result
    }

    /// Resume All of a workspace (banner button).
    func resumeAgentSessions(inWorkspace workspaceID: String) {
        guard let workspace = workspace(id: workspaceID) else { return }
        for pane in workspace.orderedPanes where pane.resumeOffer != nil { _ = requestResume(pane) }
    }

    /// Queues one pane. Returns why it cannot be resumed, or nil when queued (or already waiting).
    func requestResume(_ pane: Pane) -> String? {
        guard let offer = pane.resumeOffer else {
            if pane.agentUsage != nil { return "an agent is running in this pane" }
            return pane.agentSession == nil ? "no remembered agent session in this pane" : "already resumed"
        }
        guard AgentResume.command(for: offer) != nil else { return "the session id cannot be resumed" }
        if pane.agentUsage != nil {
            clearResumeOffer(pane)
            return "an agent is running in this pane"
        }
        if pane.resumeRequestedAt == nil { pane.resumeRequestedAt = Date() }
        // Asking to resume an SSH pane that is not connected connects it (the user asked; never on launch).
        if let ssh = pane.ssh, !ssh.connected { try? connectSSH(paneID: pane.id) }
        updateResumeBanner(pane)
        startResumeTimerIfNeeded()
        return nil
    }

    /// Dismiss: forget the offer (and the session, so it is not offered after the next launch either).
    func dismissResume(_ pane: Pane) {
        guard pane.resumeOffer != nil else { return }
        let wasWaiting = pane.resumeRequestedAt != nil
        clearResumeOffer(pane)
        // Cancelling a queued resume keeps the session for the next launch; dismissing an offer forgets it.
        if !wasWaiting { forgetAgentSession(pane) }
        scheduleSave()
    }

    func clearResumeOffer(_ pane: Pane) {
        pane.resumeOffer = nil
        pane.resumeRequestedAt = nil
        pane.resumeScreen = nil
        pane.resumeScreenSince = nil
        updateResumeBanner(pane)
        // The number of offers in the workspace changed: refresh the other banners' Resume All.
        workspace(id: pane.workspaceID)?.panes.values.filter { $0 !== pane && $0.resumeOffer != nil }.forEach(updateResumeBanner)
    }

    /// The banner's `Claude Code session “Fix login” (Opus, 3 hours ago)`; `AgentSession.summary()` is the CLI's English one.
    static func localizedSummary(_ session: AgentSession, now: Date = Date()) -> String {
        let name = AgentResume.displayName(session.agent)
        var details: [String] = []
        if let model = session.model, !model.isEmpty { details.append(model) }
        details.append(now.timeIntervalSince(session.lastSeen) < 60 ? String(localized: "just now")
                       : RelativeDateTimeFormatter().localizedString(for: session.lastSeen, relativeTo: now))
        let detail = details.joined(separator: String(localized: ", ", comment: "list separator"))
        if let title = AgentResume.cleanTitle(session.title) {
            return String(localized: "\(name) session “\(title)” (\(detail))")
        }
        return String(localized: "\(name) session (\(detail))")
    }

    func updateResumeBanner(_ pane: Pane) {
        guard let offer = pane.resumeOffer, let command = AgentResume.command(for: offer) else {
            pane.container.setBanner(nil)
            return
        }
        let summary = Self.localizedSummary(offer)
        let banner: AgentResumeBannerView
        if pane.resumeRequestedAt != nil {
            banner = AgentResumeBannerView(state: .waiting(summary: summary))
        } else {
            let others = workspace(id: pane.workspaceID)?.panes.values
                .filter { $0 !== pane && $0.resumeOffer != nil && $0.resumeRequestedAt == nil }.count ?? 0
            banner = AgentResumeBannerView(state: .offered(summary: summary, command: command, others: others))
        }
        banner.onResume = { [weak self, weak pane] in
            guard let self, let pane else { return }
            _ = self.requestResume(pane)
        }
        banner.onResumeAll = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.resumeAgentSessions(inWorkspace: pane.workspaceID)
        }
        banner.onDismiss = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.dismissResume(pane)
        }
        pane.container.setBanner(banner)
    }

    func startResumeTimerIfNeeded() {
        guard resumeTimer == nil, workspaces.contains(where: { $0.panes.values.contains { $0.resumeRequestedAt != nil } }) else { return }
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        resumeTimer = timer
    }

    private func resumeTick(now: Date = Date()) {
        var waiting = false
        for workspace in workspaces {
            for pane in workspace.orderedPanes where pane.resumeRequestedAt != nil && pane.resumeOffer != nil {
                switch resumeReadiness(pane, now: now) {
                case .wait:
                    waiting = true
                case .agentRunning:
                    // Rule: never type over a running agent; the offer is moot.
                    clearResumeOffer(pane)
                case .ready:
                    performResume(pane)
                }
            }
        }
        if !waiting {
            resumeTimer?.invalidate()
            resumeTimer = nil
        }
    }

    private enum Readiness { case wait, ready, agentRunning }

    private func resumeReadiness(_ pane: Pane, now: Date) -> Readiness {
        guard !pane.isClosing, let terminal = pane.terminal else { return .wait } // SSH pane not connected yet
        if pane.agentUsage != nil { return .agentRunning }
        let isSSH = pane.ssh != nil
        if let ssh = pane.ssh {
            guard ssh.connected, now.timeIntervalSince(pane.terminalStartedAt) >= 1.5 else { return .wait }
        } else {
            guard now.timeIntervalSince(pane.terminalStartedAt) >= 0.8,
                  let group = terminal.foregroundProcessGroupID else { return .wait }
            switch PaneProcessProbe.classify(pid: group) {
            case .agent: return .agentRunning
            case .other, nil:
                pane.resumeScreen = nil
                return .wait
            case .shell: break
            }
        }
        let screen = terminal.visibleText()
        guard !screen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .wait }
        if screen != pane.resumeScreen {
            pane.resumeScreen = screen
            pane.resumeScreenSince = now
            return .wait
        }
        let stable = now.timeIntervalSince(pane.resumeScreenSince ?? now)
        // Always: the cursor sits right after a prompt with nothing typed (never into an editor, a password
        // question or a half-typed command). A remote prompt report only shortens the wait.
        guard AgentResume.isAtEmptyPrompt(screen: screen, cursor: terminal.cursorPosition) else { return .wait }
        if isSSH {
            let prompted = (pane.lastPromptReportAt ?? .distantPast) > pane.terminalStartedAt
            return stable >= (prompted ? 0.4 : 1.5) ? .ready : .wait
        }
        return stable >= 0.4 ? .ready : .wait
    }

    /// Types the resume command once. A local pane is checked for agent processes on its tty first.
    private func performResume(_ pane: Pane) {
        guard let offer = pane.resumeOffer, let command = AgentResume.command(for: offer), let terminal = pane.terminal else {
            clearResumeOffer(pane)
            return
        }
        if pane.ssh == nil, let group = terminal.foregroundProcessGroupID, PaneProcessProbe.agentOnTerminal(of: group) {
            clearResumeOffer(pane)
            return
        }
        // Consumed before typing: whatever happens next, this offer is never typed again.
        clearResumeOffer(pane)
        pane.agentSession = offer
        pane.resumedSessionID = offer.sessionID
        terminal.typeText(command + "\r")
        scheduleSave()
    }
}

/// What runs in the foreground of a local pane's terminal.
enum PaneProcessProbe {
    enum Kind { case shell, agent, other }

    /// The process group leader `pid`: a shell, a coding agent (Claude Code / Codex) or something else.
    static func classify(pid: pid_t) -> Kind? {
        guard let info = bsdInfo(pid) else { return nil }
        if isAgent(pid) { return .agent }
        let name = withUnsafeBytes(of: info.pbi_comm) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        let shells = AgentProcessClassifier.shells.subtracting(["env", "timeout", "nice", "nohup"])
        let base = name.hasPrefix("-") ? String(name.dropFirst()) : name // login shells: `-zsh`
        return shells.contains(base) ? .shell : .other
    }

    /// Any Claude Code / Codex process on the same terminal as `pid` (also backgrounded ones).
    static func agentOnTerminal(of pid: pid_t) -> Bool {
        guard let info = kinfo(pid), info.kp_eproc.e_tdev != -1 else { return false }
        let tty = info.kp_eproc.e_tdev
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        for candidate in pids.prefix(Int(max(0, count))) where candidate > 0 {
            guard let other = kinfo(candidate), other.kp_eproc.e_tdev == tty else { continue }
            if isAgent(candidate) { return true }
        }
        return false
    }

    private static func isAgent(_ pid: pid_t) -> Bool {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let executable = proc_pidpath(pid, &path, UInt32(path.count)) > 0 ? String(cString: path) : ""
        let agent = AgentProcessClassifier.agent(executablePath: executable, arguments: arguments(pid))
        if agent == .codex { return AgentProcessClassifier.codexRole(arguments: arguments(pid)) == .session }
        return agent == .claude
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    private static func kinfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    private static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return buffer.withUnsafeBytes { raw in
            ProcessArguments.parse(UnsafeRawBufferPointer(rebasing: raw[0..<size]))?.arguments ?? []
        }
    }
}
