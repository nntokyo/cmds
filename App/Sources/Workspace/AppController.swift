import AppKit
import Combine
import CmdsCore
import UserNotifications

extension Notification.Name {
    /// Mirrors `AppController.changes`; `userInfo` has `"change"` (`StateChange`) and,
    /// when applicable, `"workspaceID"` / `"paneID"` strings.
    static let cmdsStateDidChange = Notification.Name("cmdsStateDidChange")
}

/// What changed in `AppController`. Subscribers re-read the state they care about.
enum StateChange: Equatable {
    /// Workspace list, order or selection changed (also on create/close).
    case workspaces
    /// Metadata, layout or focus of one workspace changed.
    case workspace(id: String)
    /// Title, cwd, url or attention of one pane changed.
    case pane(workspaceID: String, paneID: String)
    /// A pane posted a notification (OSC 9/777, bell, `notify`). Emitted even when the pane is focused.
    case notification(workspaceID: String, paneID: String, title: String?, body: String)

    var workspaceID: String? {
        switch self {
        case .workspaces: return nil
        case .workspace(let id): return id
        case .pane(let id, _), .notification(let id, _, _, _): return id
        }
    }

    var paneID: String? {
        switch self {
        case .pane(_, let id), .notification(_, let id, _, _): return id
        default: return nil
        }
    }
}

enum SplitDirection: String, Sendable {
    case right
    case down

    var axis: SplitAxis { self == .right ? .horizontal : .vertical }
}

/// Single source of truth for workspaces and panes. UI, socket API and sync server all go through it.
/// Methods taking an optional ID fall back to the selected workspace / its focused pane.
/// Errors are `RPCError`s so the socket layer can forward them unchanged.
@MainActor
final class AppController {
    static let shared = AppController()

    private(set) var workspaces: [Workspace] = []
    private(set) var selectedWorkspaceID: String?
    /// The main window; used to decide whether a focused pane is actually visible to the user.
    weak var window: NSWindow?
    let socketPath = CmdsEnv.defaultSocketPath()

    /// Fires synchronously on the main actor after every state change.
    var changes: AnyPublisher<StateChange, Never> { subject.eraseToAnyPublisher() }

    /// Fires on the main actor after each resource-usage sample (~every 2 s): per-workspace CPU/memory and
    /// `systemStats`. Kept out of `changes` so usage never triggers full UI refreshes, session saves or
    /// socket events.
    var usageChanges: AnyPublisher<Void, Never> { usageSubject.eraseToAnyPublisher() }

    /// Machine-wide usage from the latest sample; nil until two samples were taken (~1 s after launch).
    private(set) var systemStats: SystemStats?
    /// `systemStats` plus the memory breakdown (sidebar tooltip).
    private(set) var systemSample: SystemSample?

    /// Latest account limits per agent kind (from whichever pane reported them last).
    private(set) var agentLimitsByKind: [AgentKind: AgentLimits] = [:]
    private var agentRefreshScheduled = false
    /// Agent usage without updates for this long is marked stale (idle agent).
    static let agentStaleAfter: TimeInterval = 180
    /// Reported usage without a process to watch is dropped after this long without updates.
    static let unwatchedAgentTimeout: TimeInterval = 30 * 60

    private let subject = PassthroughSubject<StateChange, Never>()
    private let usageSubject = PassthroughSubject<Void, Never>()
    /// IDs keep counting across launches (and instances), so a stale ID held by a script or the phone
    /// never reaches a different pane after a restart.
    private var nextWorkspaceNumber: Int {
        get { max(1, UserDefaults.standard.integer(forKey: "nextWorkspaceNumber")) }
        set { UserDefaults.standard.set(newValue, forKey: "nextWorkspaceNumber") }
    }
    private var nextPaneNumber: Int {
        get { max(1, UserDefaults.standard.integer(forKey: "nextPaneNumber")) }
        set { UserDefaults.standard.set(newValue, forKey: "nextPaneNumber") }
    }
    private var saveWorkItem: DispatchWorkItem?
    /// Polls panes with a queued agent-session resume until their shell prompt is ready (AppController+AgentSessions).
    var resumeTimer: Timer?

    var selectedWorkspace: Workspace? { selectedWorkspaceID.flatMap(workspace(id:)) }
    var focusedPane: Pane? { selectedWorkspace?.focusedPane }

    func workspace(id: String) -> Workspace? { workspaces.first { $0.id == id } }

    func pane(id: String) -> Pane? {
        for workspace in workspaces { if let pane = workspace.panes[id] { return pane } }
        return nil
    }

    // MARK: - Queries

    func listWorkspaces() -> [WorkspaceInfo] {
        workspaces.map { $0.info(selected: $0.id == selectedWorkspaceID) }
    }

    func workspaceInfo(id: String?) throws -> WorkspaceInfo {
        let workspace = try resolveWorkspace(id)
        return workspace.info(selected: workspace.id == selectedWorkspaceID)
    }

    func listPanes(workspaceID: String? = nil) throws -> [PaneInfo] {
        try resolveWorkspace(workspaceID).paneInfos()
    }

    func paneInfo(id: String?) throws -> PaneInfo {
        let pane = try resolvePane(id)
        return pane.info(focused: workspace(id: pane.workspaceID)?.focusedPaneID == pane.id)
    }

    func workspaceID(forPane paneID: String) -> String? { pane(id: paneID)?.workspaceID }

    /// Result of the socket method `system.stats`.
    func statsSnapshot() -> StatsSnapshot {
        let limits = activeAgentLimits()
        return StatsSnapshot(system: systemStats, workspaces: workspaces.map {
            WorkspaceStats(id: $0.id, cpuPercent: $0.cpuPercent, memoryBytes: $0.memoryBytes)
        }, agentLimits: limits.isEmpty ? nil : limits, keepAwake: KeepAwakeManager.shared.status)
    }

    // MARK: - Agents

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
    /// With `pid` (the agent process) the usage is dropped as soon as that process exits.
    func reportAgentUsage(paneID: String?, usage: AgentUsage, pid: Int32?) throws {
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
        pane.agentUsage = usage
        pane.agentSource = .report(process: process)
        rememberAgentSession(pane, usage: usage)
        if appeared { emit(.pane(workspaceID: pane.workspaceID, paneID: pane.id)) }
        scheduleAgentRefresh()
    }

    /// `agent.claude_hook`: a Claude Code hook payload forwarded as is (`cmds-remote.sh hook claude` on a server).
    /// The transcript is never read (it is a path on another machine); `Stop` uses `last_assistant_message`.
    func claudeHook(paneID: String?, input: JSONValue) throws {
        let pane = try resolvePane(paneID)
        let data = try JSONEncoder().encode(input)
        guard let notification = ClaudeHook.notification(fromHookInput: data, readTranscript: false) else { return }
        raiseAttention(pane: pane, title: notification.title, body: notification.body)
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

    /// Applies a metadata scan: drops usage of agents that exited, marks idle ones stale, takes Codex usage from its
    /// session files (a pane reporting through `agent.report` keeps that) and the newest Codex limits.
    /// The caller sends the usage update (`applyResourceUsage`) right after.
    func applyAgentScan(_ codex: CodexWatchResult, now: Date = Date()) {
        if let limits = codex.limits, limits.updatedAt > (agentLimitsByKind[.codex]?.updatedAt ?? .distantPast) {
            agentLimitsByKind[.codex] = limits
        }
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
                    if exited { forgetAgentSession(pane) }
                case .codexSession?:
                    if !codex.panes.contains(pane.id) {
                        (usage, source) = (nil, nil)
                        forgetAgentSession(pane)
                    }
                case nil:
                    break
                }
                if source == nil || source == .codexSession, let fresh = codex.usage[pane.id] {
                    usage = fresh
                    source = .codexSession
                    if fresh != pane.agentUsage { rememberAgentSession(pane, usage: fresh) }
                }
                if var current = usage {
                    current.stale = now.timeIntervalSince(current.updatedAt) > Self.agentStaleAfter ? true : nil
                    usage = current
                }
                let appearedOrGone = (usage?.agent) != (pane.agentUsage?.agent)
                pane.agentSource = source
                guard usage != pane.agentUsage else { continue }
                pane.agentUsage = usage
                if appearedOrGone { emit(.pane(workspaceID: workspace.id, paneID: pane.id)) }
            }
        }
    }

    /// Reports arrive often; redraw usage labels (sidebar, phone) at most a few times a second.
    func scheduleAgentRefresh() {
        guard !agentRefreshScheduled else { return }
        agentRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                self?.agentRefreshScheduled = false
                self?.usageSubject.send()
            }
        }
    }

    // MARK: - Workspaces

    /// Creates and selects a workspace with one terminal pane. `cwd` defaults to the home directory.
    @discardableResult
    func createWorkspace(title: String? = nil, cwd: String? = nil, command: String? = nil) -> WorkspaceInfo {
        let workspace = makeWorkspace()
        workspace.customTitle = title
        let directory = cwd.map { ($0 as NSString).expandingTildeInPath } ?? NSHomeDirectory()
        let pane = makePane(kind: .terminal, in: workspace, cwd: directory, command: command, url: nil)
        workspace.root = SplitNode(paneID: pane.id)
        workspace.focusedPaneID = pane.id
        workspace.workingDirectory = directory
        workspace.gitBranch = GitInfo.branch(at: directory)
        workspaces.append(workspace)
        selectedWorkspaceID = workspace.id
        emit(.workspaces)
        focusSelectedPaneView()
        return workspace.info(selected: true)
    }

    /// Creates and selects a workspace with one SSH pane, connected right away.
    @discardableResult
    func createSSHWorkspace(_ launch: SSHLaunch, title: String? = nil) throws -> WorkspaceInfo {
        let workspace = makeWorkspace()
        workspace.customTitle = title
        let pane = makeSSHPane(launch, in: workspace)
        workspace.root = SplitNode(paneID: pane.id)
        workspace.focusedPaneID = pane.id
        updateLocation(of: workspace, from: pane)
        workspaces.append(workspace)
        selectedWorkspaceID = workspace.id
        try connectSSH(pane: pane, emitChange: false)
        emit(.workspaces)
        focusSelectedPaneView()
        return workspace.info(selected: true)
    }

    func selectWorkspace(id: String) throws {
        let workspace = try resolveWorkspace(id)
        guard workspace.id != selectedWorkspaceID else { return }
        selectedWorkspaceID = workspace.id
        if isWindowKey, let pane = workspace.focusedPane { clearAttention(pane) }
        emit(.workspaces)
        focusSelectedPaneView()
    }

    func closeWorkspace(id: String?) throws {
        let workspace = try resolveWorkspace(id)
        guard let index = workspaces.firstIndex(where: { $0 === workspace }) else { return }
        workspace.panes.values.forEach { $0.tearDown() }
        workspace.panes.removeAll()
        workspaces.remove(at: index)
        if selectedWorkspaceID == workspace.id {
            selectedWorkspaceID = workspaces.isEmpty ? nil : workspaces[min(index, workspaces.count - 1)].id
        }
        updateDockBadge()
        emit(.workspaces)
        focusSelectedPaneView()
    }

    func renameWorkspace(id: String?, title: String) throws {
        let workspace = try resolveWorkspace(id)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        workspace.customTitle = trimmed.isEmpty ? nil : trimmed
        emit(.workspace(id: workspace.id))
    }

    func moveWorkspace(id: String, to newIndex: Int) throws {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else {
            throw RPCError.notFound("workspace not found: \(id)")
        }
        let workspace = workspaces.remove(at: index)
        workspaces.insert(workspace, at: max(0, min(newIndex, workspaces.count)))
        emit(.workspaces)
    }

    /// Sets the sidebar notification text without lighting the ring.
    func setStatus(workspaceID: String?, text: String) throws {
        let workspace = try resolveWorkspace(workspaceID)
        workspace.notificationText = text.isEmpty ? nil : text
        emit(.workspace(id: workspace.id))
    }

    // MARK: - Panes

    /// Splits `paneID` (default: focused pane) and focuses the new pane.
    /// New terminals start in the source pane's directory unless `cwd` is given. With `focus: false` the source
    /// pane keeps focus (scripts and agents opening a helper pane must not take the user's keyboard).
    @discardableResult
    func split(paneID: String? = nil, direction: SplitDirection, kind: PaneKind = .terminal,
               url: String? = nil, cwd: String? = nil, command: String? = nil, focus: Bool = true,
               ssh: SSHLaunch? = nil, file: PreviewTarget? = nil) throws -> PaneInfo {
        let source = try resolvePane(paneID)
        guard let workspace = workspace(id: source.workspaceID),
              let leaf = workspace.root?.leaf(for: source.id) else {
            throw RPCError.notFound("pane not found: \(source.id)")
        }
        // A plain terminal split of an SSH pane opens another connection to the same host, in its remote directory.
        var ssh = ssh
        if ssh == nil, kind == .terminal, cwd == nil, command == nil, let sourceSSH = source.ssh {
            ssh = (try? SSHLaunch(host: sourceSSH.launch.host, remoteCwd: source.workingDirectory)) ?? sourceSSH.launch
        }
        let pane: Pane
        if let ssh, kind == .terminal {
            pane = makeSSHPane(ssh, in: workspace)
            try connectSSH(pane: pane, emitChange: false)
        } else {
            // Remote paths mean nothing here: local terminals split from an SSH pane start in the workspace's
            // local directory (else home).
            let localSource = source.ssh == nil ? source.workingDirectory : nil
            let localWorkspace = workspace.isRemote ? nil : workspace.workingDirectory
            let directory = cwd.map { ($0 as NSString).expandingTildeInPath } ?? localSource ?? localWorkspace ?? NSHomeDirectory()
            pane = makePane(kind: kind, in: workspace, cwd: directory, command: command, url: url, file: file)
        }
        workspace.zoomedPaneID = nil
        leaf.split(axis: direction.axis, newPaneID: pane.id)
        guard focus else {
            emit(.workspace(id: workspace.id))
            return pane.info(focused: false)
        }
        applyFocus(pane, in: workspace)
        emit(.workspace(id: workspace.id))
        if workspace.id == selectedWorkspaceID { pane.focus() }
        return pane.info(focused: true)
    }

    /// Focuses a pane, selecting its workspace if needed. Clears its attention ring.
    func focusPane(id: String) throws {
        let pane = try resolvePane(id)
        guard let workspace = workspace(id: pane.workspaceID) else { return }
        let changedWorkspace = workspace.id != selectedWorkspaceID
        selectedWorkspaceID = workspace.id
        applyFocus(pane, in: workspace)
        clearAttention(pane)
        emit(changedWorkspace ? .workspaces : .workspace(id: workspace.id))
        pane.focus()
    }

    /// Closes a pane; the split tree collapses. Closing the last pane closes the workspace.
    func closePane(id: String?) throws {
        let pane = try resolvePane(id)
        guard let workspace = workspace(id: pane.workspaceID), let root = workspace.root else { return }
        let order = workspace.orderedPanes.map(\.id)
        pane.tearDown()
        workspace.panes[pane.id] = nil
        workspace.root = SplitNode.removing(pane.id, from: root)
        if workspace.zoomedPaneID == pane.id { workspace.zoomedPaneID = nil }
        updateDockBadge()
        guard workspace.root != nil else {
            try closeWorkspace(id: workspace.id)
            return
        }
        if workspace.focusedPaneID == pane.id {
            // Focus the pane that followed (or preceded) the closed one in reading order.
            let index = order.firstIndex(of: pane.id) ?? 0
            let remaining = workspace.orderedPanes
            if let next = remaining[safe: min(index, remaining.count - 1)] { applyFocus(next, in: workspace) }
        }
        emit(.workspace(id: workspace.id))
        if workspace.id == selectedWorkspaceID { focusSelectedPaneView() }
    }

    func sendText(paneID: String?, text: String) throws {
        try terminal(for: paneID).sendText(text)
    }

    /// Like `sendText`, but printable text arrives as keystrokes rather than a paste.
    func typeText(paneID: String?, text: String) throws {
        try terminal(for: paneID).typeText(text)
    }

    /// Visible screen text, or scrollback + screen capped to `scrollback` lines.
    func readText(paneID: String?, scrollback: Int? = nil) throws -> String {
        let terminal = try terminal(for: paneID)
        if let scrollback { return terminal.scrollbackText(maxLines: scrollback) }
        return terminal.visibleText()
    }

    /// Visible screen with its grid size and cursor, read back to back.
    func screenState(paneID: String?) throws -> (text: String, grid: (rows: Int, cols: Int)?, cursor: (row: Int, col: Int)?) {
        let terminal = try terminal(for: paneID)
        return (terminal.visibleText(), terminal.gridSize, terminal.cursorPosition)
    }

    /// Lights the pane's ring (unless it is the focused pane in the key window), updates the sidebar
    /// text and posts a macOS notification while the app is inactive.
    func notify(paneID: String?, title: String?, body: String) throws {
        raiseAttention(pane: try resolvePane(paneID), title: title, body: body)
    }

    func toggleZoom(paneID: String? = nil) throws {
        let pane = try resolvePane(paneID)
        guard let workspace = workspace(id: pane.workspaceID) else { return }
        workspace.zoomedPaneID = workspace.zoomedPaneID == nil && workspace.panes.count > 1 ? pane.id : nil
        applyFocus(pane, in: workspace)
        emit(.workspace(id: workspace.id))
        if workspace.id == selectedWorkspaceID { pane.focus() }
    }

    // MARK: - Browser

    /// Opens a browser split to the right of `paneID` (default: focused pane).
    @discardableResult
    func openBrowser(paneID: String? = nil, url: String, focus: Bool = true) throws -> PaneInfo {
        try split(paneID: paneID, direction: .right, kind: .browser, url: url, focus: focus)
    }

    func browser(paneID: String) throws -> BrowserPane {
        let pane = try resolvePane(paneID)
        guard let browser = pane.browser else { throw RPCError.invalidParams("pane \(pane.id) is not a browser") }
        return browser
    }

    func browserNavigate(paneID: String, url: String) throws {
        try browser(paneID: paneID).navigate(to: url)
    }

    func browserLocation(paneID: String) throws -> (url: String?, title: String) {
        let browser = try browser(paneID: paneID)
        return (browser.currentURL?.absoluteString, browser.pageTitle)
    }

    func browserEvaluate(paneID: String, script: String) async throws -> JSONValue {
        try await browser(paneID: paneID).evaluateJavaScript(script)
    }

    func browserSnapshot(paneID: String) async throws -> Data {
        try await browser(paneID: paneID).snapshot()
    }

    // MARK: - Preview

    /// `pane.open_file`: shows a local file in a preview pane split off `paneID` (default: focused pane). When
    /// `paneID` is a preview pane, the file replaces what it shows instead. `path` must be absolute and an existing
    /// file (the CLI resolves relative paths against its cwd).
    @discardableResult
    func openFile(paneID: String? = nil, path: String, direction: SplitDirection = .right, focus: Bool = true,
                  format: PreviewFormat? = nil) throws -> PaneInfo {
        let target = try PreviewTarget.checked(path: path, format: format)
        let source = try resolvePane(paneID)
        if let preview = source.preview {
            preview.open(path: target.path, format: target.format)
            if focus { try focusPane(id: source.id) }
            return try paneInfo(id: source.id)
        }
        return try split(paneID: source.id, direction: direction, kind: .preview, focus: focus, file: target)
    }

    /// ⌘-click on a file path in a terminal: shows it in the workspace's preview pane if it has one, else in a new
    /// preview split to the right. The terminal keeps the keyboard.
    func openFileFromTerminal(_ pane: Pane, path: String) {
        guard let workspace = workspace(id: pane.workspaceID) else { return }
        let existing = workspace.orderedPanes.first { $0.kind == .preview }
        do {
            try openFile(paneID: existing?.id ?? pane.id, path: path, focus: false)
        } catch {
            NSSound.beep()
        }
    }

    /// The file shown in a preview pane (for the phone's `requestFile`; never a path from the request).
    func previewFile(paneID: String) throws -> String {
        let pane = try resolvePane(paneID)
        guard let preview = pane.preview else { throw RPCError.invalidParams("pane \(pane.id) is not a preview pane") }
        guard preview.fileExists else { throw RPCError.notFound("file not found: \(preview.fileName)") }
        return preview.path
    }

    // MARK: - UI commands

    func selectWorkspace(at index: Int) {
        guard workspaces.indices.contains(index) else { return }
        try? selectWorkspace(id: workspaces[index].id)
    }

    func selectAdjacentWorkspace(offset: Int) {
        guard !workspaces.isEmpty else { return }
        let current = workspaces.firstIndex { $0.id == selectedWorkspaceID } ?? 0
        let count = workspaces.count
        selectWorkspace(at: ((current + offset) % count + count) % count)
    }

    /// Focuses the pane whose attention was raised most recently.
    func jumpToLatestAttention() {
        let latest = workspaces.flatMap { $0.panes.values }
            .filter(\.attention)
            .max { ($0.attentionDate ?? .distantPast) < ($1.attentionDate ?? .distantPast) }
        if let latest { try? focusPane(id: latest.id) }
    }

    var attentionCount: Int { workspaces.reduce(0) { $0 + $1.panes.values.filter(\.attention).count } }

    /// Called when the window becomes key / the app becomes active: the visible focused pane is "seen".
    func windowDidBecomeKey() {
        if let pane = focusedPane, pane.attention {
            clearAttention(pane)
            emit(.workspace(id: pane.workspaceID))
        }
    }

    // MARK: - Pane callbacks

    func paneDidBecomeFocused(_ pane: Pane) {
        guard let workspace = workspace(id: pane.workspaceID), !pane.isClosing else { return }
        guard workspace.focusedPaneID != pane.id || pane.attention || workspace.id != selectedWorkspaceID else { return }
        let changedWorkspace = workspace.id != selectedWorkspaceID
        selectedWorkspaceID = workspace.id
        applyFocus(pane, in: workspace)
        clearAttention(pane)
        emit(changedWorkspace ? .workspaces : .workspace(id: workspace.id))
    }

    func paneDidChange(_ pane: Pane) {
        emit(.pane(workspaceID: pane.workspaceID, paneID: pane.id))
    }

    func paneDidChangeWorkingDirectory(_ pane: Pane) {
        guard let workspace = workspace(id: pane.workspaceID) else { return }
        if workspace.focusedPaneID == pane.id, pane.workingDirectory != nil {
            updateLocation(of: workspace, from: pane)
            emit(.workspace(id: workspace.id))
        }
        emit(.pane(workspaceID: workspace.id, paneID: pane.id))
    }

    // MARK: - SSH panes

    /// `remote.location`: cwd and git branch reported by the remote shell (`cmds-remote.sh prompt`).
    func setRemoteLocation(paneID: String?, cwd: String?, branch: String?) throws {
        let pane = try resolvePane(paneID)
        guard let ssh = pane.ssh else { throw RPCError.invalidParams("pane \(pane.id) is not an SSH pane") }
        pane.lastPromptReportAt = Date() // the remote shell is at its prompt (resume readiness)
        let cwd = cwd.flatMap { $0.isEmpty || $0.count > 4096 ? nil : $0 }
        let branch = branch.flatMap { $0.isEmpty || $0.count > 256 ? nil : $0 }
        guard cwd != nil && cwd != pane.workingDirectory || branch != ssh.remoteBranch else { return }
        if let cwd { pane.workingDirectory = cwd }
        ssh.remoteBranch = branch
        paneDidChangeWorkingDirectory(pane)
    }

    /// Starts (or restarts) the `ssh` of an SSH pane: a new terminal surface running the same command with a fresh
    /// remote socket. The pane's restricted API socket is created on first use.
    func connectSSH(paneID: String?) throws {
        try connectSSH(pane: try resolvePane(paneID), emitChange: true)
    }

    private func connectSSH(pane: Pane, emitChange: Bool) throws {
        guard let ssh = pane.ssh else { throw RPCError.invalidParams("pane \(pane.id) is not an SSH pane") }
        guard !ssh.connected else { return }
        if !ssh.startAPI(controller: self, scope: RemoteScope(paneID: pane.id, workspaceID: pane.workspaceID)) {
            // Still connect: the terminal works, only `cmds-remote.sh` will report that it is unavailable.
            NSLog("cmds: could not create the API socket of SSH pane \(pane.id)")
        }
        let config = ssh.makeLaunchConfig(paneID: pane.id, workspaceID: pane.workspaceID,
                                          environment: terminalEnvironment(paneID: pane.id, workspaceID: pane.workspaceID))
        pane.attach(terminal: TerminalEngineProvider.shared.makeSurface(config: config))
        ssh.didConnect()
        pane.setSSHOverlay(nil)
        guard emitChange else { return }
        emit(.pane(workspaceID: pane.workspaceID, paneID: pane.id))
        emit(.workspace(id: pane.workspaceID))
        if let workspace = workspace(id: pane.workspaceID), workspace.focusedPaneID == pane.id,
           workspace.id == selectedWorkspaceID {
            pane.focus()
        }
    }

    /// The pane's `ssh` exited: keep the pane and its last screen, show the Reconnect overlay, drop agent usage
    /// reported over that connection.
    func sshDidDisconnect(_ pane: Pane) {
        guard let ssh = pane.ssh, ssh.connected else { return }
        ssh.didDisconnect()
        if pane.agentUsage != nil {
            // The agent on the server went with the connection: offer to resume it after reconnecting.
            offerResumeAfterDisconnect(pane)
            pane.agentUsage = nil
            pane.agentSource = nil
            scheduleAgentRefresh()
        }
        pane.setSSHOverlay(.disconnected)
        if let workspace = workspace(id: pane.workspaceID), workspace.focusedPaneID == pane.id,
           workspace.id == selectedWorkspaceID {
            pane.focus()
        }
        emit(.pane(workspaceID: pane.workspaceID, paneID: pane.id))
        emit(.workspace(id: pane.workspaceID))
    }

    /// Focused pane is an SSH pane whose `ssh` is not running (⌘R reconnects).
    var focusedDisconnectedSSHPane: Pane? {
        guard let pane = focusedPane, let ssh = pane.ssh, !ssh.connected else { return nil }
        return pane
    }

    /// Workspace cwd/branch from the pane: local panes ask git here, SSH panes use what their remote shell reported.
    private func updateLocation(of workspace: Workspace, from pane: Pane) {
        if let ssh = pane.ssh {
            workspace.workingDirectory = pane.workingDirectory
            workspace.gitBranch = ssh.remoteBranch
        } else {
            workspace.workingDirectory = pane.workingDirectory
            workspace.gitBranch = pane.workingDirectory.flatMap(GitInfo.branch(at:))
        }
    }

    /// A divider was dragged; ratios are already stored in the split tree.
    func layoutDidChange(workspaceID: String) {
        emit(.workspace(id: workspaceID))
    }

    func surfaceDidClose(_ pane: Pane) {
        try? closePane(id: pane.id)
    }

    func raiseAttention(pane: Pane, title: String?, body: String) {
        guard let workspace = workspace(id: pane.workspaceID) else { return }
        let text = [title, body].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ": ")
        workspace.notificationText = text.isEmpty ? nil : text
        emit(.notification(workspaceID: workspace.id, paneID: pane.id, title: title, body: body))
        if !isVisiblyFocused(pane) {
            pane.setAttention(true)
            updateDockBadge()
            if !NSApp.isActive { postUserNotification(pane: pane, workspace: workspace, title: title, body: body) }
            emit(.pane(workspaceID: workspace.id, paneID: pane.id))
        }
        emit(.workspace(id: workspace.id))
    }

    /// Applies results of the background metadata scan (git branch, listening ports).
    func applyMetadata(_ metadata: [String: WorkspaceMetadata]) {
        for workspace in workspaces {
            guard let update = metadata[workspace.id] else { continue }
            if workspace.isRemote {
                // cwd and branch are remote (reported by the server); only local ports (e.g. `ssh -L`) apply.
                if update.ports != workspace.ports {
                    workspace.ports = update.ports
                    emit(.workspace(id: workspace.id))
                }
                continue
            }
            if update.workingDirectory != workspace.workingDirectory { continue } // cwd moved meanwhile
            if update.gitBranch != workspace.gitBranch || update.ports != workspace.ports {
                workspace.gitBranch = update.gitBranch
                workspace.ports = update.ports
                emit(.workspace(id: workspace.id))
            }
        }
    }

    /// Applies a resource-usage sample (from the same background scan). Workspaces missing from `usage`
    /// had no live process. `system` is nil until the sampler has two readings.
    func applyResourceUsage(_ usage: [String: ResourceUsage], system: SystemSample?) {
        for workspace in workspaces { workspace.applyUsage(usage[workspace.id]) }
        if let system {
            systemSample = system
            systemStats = system.stats
        }
        usageSubject.send()
    }

    // MARK: - Session

    func sessionState() -> SessionState {
        func node(_ split: SplitNode, in workspace: Workspace) -> SessionState.Node {
            switch split.content {
            case .leaf(let id):
                let pane = workspace.panes[id]
                if pane?.kind == .browser { return .browser(url: pane?.url) }
                if let preview = pane?.preview { return .preview(path: preview.path, format: preview.forcedFormat?.rawValue) }
                if let pane, let ssh = pane.ssh {
                    let cwd = (try? SSHLaunch.validateRemoteCwd(pane.workingDirectory)) ?? ssh.launch.remoteCwd
                    return .ssh(host: ssh.launch.host, remoteCwd: cwd)
                }
                return .terminal(cwd: pane?.workingDirectory)
            case .split(let axis, let first, let second):
                return .split(axis: axis, ratio: split.ratio, first: node(first, in: workspace), second: node(second, in: workspace))
            }
        }
        let states = workspaces.compactMap { workspace -> SessionState.WorkspaceState? in
            guard let root = workspace.root else { return nil }
            let agentSessions = root.paneIDs.enumerated().compactMap { index, id -> SessionState.PaneAgentSession? in
                guard let pane = workspace.panes[id], let session = savedAgentSession(pane) else { return nil }
                return SessionState.PaneAgentSession(paneIndex: index, session: session)
            }
            return SessionState.WorkspaceState(
                title: workspace.customTitle, workingDirectory: workspace.workingDirectory,
                layout: node(root, in: workspace),
                focusedPaneIndex: workspace.focusedPaneID.flatMap { root.paneIDs.firstIndex(of: $0) },
                agentSessions: agentSessions.isEmpty ? nil : agentSessions)
        }
        return SessionState(workspaces: states, selectedIndex: workspaces.firstIndex { $0.id == selectedWorkspaceID })
    }

    /// Recreates workspaces from a saved session (cwd + layout; running programs are not restored).
    func restore(_ state: SessionState) {
        let restored = restoreWorkspaces(state, resumeMode: AgentResumeSettings.mode)
        selectedWorkspaceID = restored[safe: state.selectedIndex ?? 0]?.id ?? workspaces.first?.id
        emit(.workspaces)
        focusSelectedPaneView()
    }

    /// Appends the workspaces of `state` (after any existing ones) and applies their agent sessions with `resumeMode`.
    /// Does not select, emit or focus; returns the new workspaces in order. Also used by `state.import`.
    func restoreWorkspaces(_ state: SessionState, resumeMode: AgentResumeMode) -> [Workspace] {
        var restored: [Workspace] = []
        let fileManager = FileManager.default
        func existing(_ path: String?) -> String {
            guard let path, fileManager.fileExists(atPath: path) else { return NSHomeDirectory() }
            return path
        }
        func build(_ node: SessionState.Node, in workspace: Workspace) -> SplitNode {
            switch node {
            case .terminal(let cwd):
                return SplitNode(paneID: makePane(kind: .terminal, in: workspace, cwd: existing(cwd), command: nil, url: nil).id)
            case .browser(let url):
                return SplitNode(paneID: makePane(kind: .browser, in: workspace, cwd: nil, command: nil, url: url).id)
            case .preview(let path, let format):
                // A missing file shows a placeholder (and appears when it is created again).
                let target = PreviewTarget(path: path, format: format.flatMap(PreviewFormat.init(rawValue:)))
                return SplitNode(paneID: makePane(kind: .preview, in: workspace, cwd: nil, command: nil, url: nil, file: target).id)
            case .ssh(let host, let remoteCwd):
                // Never connects on launch: the pane shows "Not connected — Connect (⌘R)".
                guard let launch = try? SSHLaunch(host: host, remoteCwd: remoteCwd) else {
                    return SplitNode(paneID: makePane(kind: .terminal, in: workspace, cwd: NSHomeDirectory(), command: nil, url: nil).id)
                }
                let pane = makeSSHPane(launch, in: workspace)
                pane.setSSHOverlay(.notConnected)
                return SplitNode(paneID: pane.id)
            case .split(let axis, let ratio, let first, let second):
                return SplitNode(axis: axis, ratio: ratio, first: build(first, in: workspace), second: build(second, in: workspace))
            }
        }
        for saved in state.workspaces {
            let workspace = makeWorkspace()
            workspace.customTitle = saved.title
            let root = build(saved.layout, in: workspace)
            workspace.root = root
            let ids = root.paneIDs
            workspace.focusedPaneID = ids[safe: saved.focusedPaneIndex ?? 0] ?? ids.first
            if let focused = workspace.focusedPane, focused.ssh != nil {
                updateLocation(of: workspace, from: focused)
            } else {
                workspace.workingDirectory = workspace.focusedPane?.workingDirectory ?? existing(saved.workingDirectory)
                workspace.gitBranch = workspace.workingDirectory.flatMap(GitInfo.branch(at:))
            }
            workspaces.append(workspace)
            restored.append(workspace)
            restoreAgentSessions(saved.agentSessions, in: workspace, mode: resumeMode)
        }
        return restored
    }

    func saveSession() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        SessionStore.save(sessionState())
    }

    // MARK: - Internals

    private var isWindowKey: Bool { NSApp.isActive && window?.isKeyWindow == true }

    private func isVisiblyFocused(_ pane: Pane) -> Bool {
        isWindowKey && pane.workspaceID == selectedWorkspaceID && focusedPane === pane
    }

    private func makeWorkspace() -> Workspace {
        defer { nextWorkspaceNumber += 1 }
        return Workspace(id: "w\(nextWorkspaceNumber)")
    }

    private func makePane(kind: PaneKind, in workspace: Workspace, cwd: String?, command: String?, url: String?,
                          file: PreviewTarget? = nil) -> Pane {
        let id = "p\(nextPaneNumber)"
        nextPaneNumber += 1
        let pane: Pane
        switch kind {
        case .terminal:
            let environment = terminalEnvironment(paneID: id, workspaceID: workspace.id)
            let config = TerminalLaunchConfig(workingDirectory: cwd, command: command, environment: environment)
            pane = Pane(id: id, workspaceID: workspace.id, terminal: TerminalEngineProvider.shared.makeSurface(config: config))
            if pane.workingDirectory == nil { pane.workingDirectory = cwd }
        case .browser:
            let browser = BrowserPane()
            pane = Pane(id: id, workspaceID: workspace.id, browser: browser)
            if let url, !url.isEmpty { browser.navigate(to: url) } else { browser.showStartPage() }
        case .preview:
            let preview = PreviewPane(path: file?.path ?? NSHomeDirectory(), format: file?.format)
            pane = Pane(id: id, workspaceID: workspace.id, preview: preview)
        }
        pane.controller = self
        workspace.panes[id] = pane
        return pane
    }

    private func terminalEnvironment(paneID: String, workspaceID: String) -> [String: String] {
        var environment = [CmdsEnv.socketPath: socketPath, CmdsEnv.workspaceID: workspaceID, CmdsEnv.paneID: paneID]
        environment["PATH"] = BundledCLI.terminalPATH  // bundled `cmds` CLI first
        // Isolated instance: hand terminals the resolved directory (a relative CMDS_SUPPORT_DIR would point
        // the CLI elsewhere after `cd`, and it takes precedence over CMDS_SOCKET_PATH).
        if let supportDirectory = CmdsEnv.supportDirectoryOverride() {
            environment[CmdsEnv.supportDirectory] = supportDirectory
        }
        return environment
    }

    /// An SSH pane, not connected yet (`connectSSH`).
    private func makeSSHPane(_ launch: SSHLaunch, in workspace: Workspace) -> Pane {
        let id = "p\(nextPaneNumber)"
        nextPaneNumber += 1
        let pane = Pane(id: id, workspaceID: workspace.id, ssh: SSHSession(launch: launch, paneID: id))
        pane.controller = self
        workspace.panes[id] = pane
        return pane
    }

    private func applyFocus(_ pane: Pane, in workspace: Workspace) {
        let wasRemote = workspace.isRemote
        workspace.focusedPaneID = pane.id
        if let zoomed = workspace.zoomedPaneID, zoomed != pane.id { workspace.zoomedPaneID = nil }
        // Moving to or from an SSH pane always replaces the location (an SSH pane may not know its cwd yet).
        if pane.kind == .terminal,
           pane.ssh != nil || wasRemote || (pane.workingDirectory != nil && pane.workingDirectory != workspace.workingDirectory) {
            updateLocation(of: workspace, from: pane)
        }
        if isWindowKey, workspace.id == selectedWorkspaceID { clearAttention(pane) }
    }

    private func clearAttention(_ pane: Pane) {
        guard pane.attention else { return }
        pane.setAttention(false)
        updateDockBadge()
        emit(.pane(workspaceID: pane.workspaceID, paneID: pane.id))
    }

    /// Makes the selected workspace's focused pane first responder (after the UI has rebuilt).
    private func focusSelectedPaneView() {
        focusedPane?.focus()
    }

    private func updateDockBadge() {
        let count = attentionCount
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    private func postUserNotification(pane: Pane, workspace: Workspace, title: String?, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title ?? workspace.title
        content.subtitle = title == nil ? "" : workspace.title
        content.body = body
        content.sound = .default
        content.userInfo = ["paneID": pane.id]
        let request = UNNotificationRequest(identifier: "cmds.\(pane.id).\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func resolveWorkspace(_ id: String?) throws -> Workspace {
        if let id {
            guard let workspace = workspace(id: id) else { throw RPCError.notFound("workspace not found: \(id)") }
            return workspace
        }
        guard let workspace = selectedWorkspace else { throw RPCError.notFound("no workspace") }
        return workspace
    }

    func resolvePane(_ id: String?) throws -> Pane {
        if let id {
            guard let pane = pane(id: id) else { throw RPCError.notFound("pane not found: \(id)") }
            return pane
        }
        guard let pane = focusedPane else { throw RPCError.notFound("no focused pane") }
        return pane
    }

    private func terminal(for paneID: String?) throws -> TerminalSurface {
        let pane = try resolvePane(paneID)
        if pane.ssh != nil, pane.terminal == nil { throw RPCError.invalidParams("SSH pane \(pane.id) is not connected") }
        guard let terminal = pane.terminal else { throw RPCError.invalidParams("pane \(pane.id) is not a terminal") }
        return terminal
    }

    func emit(_ change: StateChange) {
        subject.send(change)
        var userInfo: [String: Any] = ["change": change]
        if let id = change.workspaceID { userInfo["workspaceID"] = id }
        if let id = change.paneID { userInfo["paneID"] = id }
        NotificationCenter.default.post(name: .cmdsStateDidChange, object: self, userInfo: userInfo)
        scheduleSave()
    }

    func scheduleSave() {
        guard saveWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveSession() }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }
}

/// A file for a preview pane: absolute, standardized path plus an optional forced rendering.
struct PreviewTarget {
    var path: String
    var format: PreviewFormat?

    /// Validates a path from the API: absolute, an existing file (not a folder).
    static func checked(path raw: String, format: PreviewFormat?) throws -> PreviewTarget {
        guard raw.hasPrefix("/") else { throw RPCError.invalidParams("path must be absolute: \(raw)") }
        let path = (raw as NSString).standardizingPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw RPCError.notFound("no such file: \(path)")
        }
        guard !isDirectory.boolValue else { throw RPCError.invalidParams("\(path) is a folder, not a file") }
        return PreviewTarget(path: path, format: format)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
