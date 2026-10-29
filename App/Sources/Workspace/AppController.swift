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
        }, agentLimits: limits.isEmpty ? nil : limits)
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
        if appeared { emit(.pane(workspaceID: pane.workspaceID, paneID: pane.id)) }
        scheduleAgentRefresh()
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
                    let gone = process.map { !$0.isAlive }
                        ?? (now.timeIntervalSince(usage?.updatedAt ?? now) > Self.unwatchedAgentTimeout)
                    if gone { (usage, source) = (nil, nil) }
                case .codexSession?:
                    if !codex.panes.contains(pane.id) { (usage, source) = (nil, nil) }
                case nil:
                    break
                }
                if source == nil || source == .codexSession, let fresh = codex.usage[pane.id] {
                    usage = fresh
                    source = .codexSession
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
    private func scheduleAgentRefresh() {
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
               url: String? = nil, cwd: String? = nil, command: String? = nil, focus: Bool = true) throws -> PaneInfo {
        let source = try resolvePane(paneID)
        guard let workspace = workspace(id: source.workspaceID),
              let leaf = workspace.root?.leaf(for: source.id) else {
            throw RPCError.notFound("pane not found: \(source.id)")
        }
        let directory = cwd.map { ($0 as NSString).expandingTildeInPath }
            ?? source.workingDirectory ?? workspace.workingDirectory ?? NSHomeDirectory()
        let pane = makePane(kind: kind, in: workspace, cwd: directory, command: command, url: url)
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
        if workspace.focusedPaneID == pane.id, let cwd = pane.workingDirectory {
            workspace.workingDirectory = cwd
            workspace.gitBranch = GitInfo.branch(at: cwd)
            emit(.workspace(id: workspace.id))
        }
        emit(.pane(workspaceID: workspace.id, paneID: pane.id))
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
                return .terminal(cwd: pane?.workingDirectory)
            case .split(let axis, let first, let second):
                return .split(axis: axis, ratio: split.ratio, first: node(first, in: workspace), second: node(second, in: workspace))
            }
        }
        let states = workspaces.compactMap { workspace -> SessionState.WorkspaceState? in
            guard let root = workspace.root else { return nil }
            return SessionState.WorkspaceState(
                title: workspace.customTitle, workingDirectory: workspace.workingDirectory,
                layout: node(root, in: workspace),
                focusedPaneIndex: workspace.focusedPaneID.flatMap { root.paneIDs.firstIndex(of: $0) })
        }
        return SessionState(workspaces: states, selectedIndex: workspaces.firstIndex { $0.id == selectedWorkspaceID })
    }

    /// Recreates workspaces from a saved session (cwd + layout; running programs are not restored).
    func restore(_ state: SessionState) {
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
            workspace.workingDirectory = workspace.focusedPane?.workingDirectory ?? existing(saved.workingDirectory)
            workspace.gitBranch = workspace.workingDirectory.flatMap(GitInfo.branch(at:))
            workspaces.append(workspace)
        }
        selectedWorkspaceID = workspaces[safe: state.selectedIndex ?? 0]?.id ?? workspaces.first?.id
        emit(.workspaces)
        focusSelectedPaneView()
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

    private func makePane(kind: PaneKind, in workspace: Workspace, cwd: String?, command: String?, url: String?) -> Pane {
        let id = "p\(nextPaneNumber)"
        nextPaneNumber += 1
        let pane: Pane
        switch kind {
        case .terminal:
            var environment = [CmdsEnv.socketPath: socketPath, CmdsEnv.workspaceID: workspace.id, CmdsEnv.paneID: id]
            environment["PATH"] = BundledCLI.terminalPATH  // bundled `cmds` CLI first
            // Isolated instance: hand terminals the resolved directory (a relative CMDS_SUPPORT_DIR would point
            // the CLI elsewhere after `cd`, and it takes precedence over CMDS_SOCKET_PATH).
            if let supportDirectory = CmdsEnv.supportDirectoryOverride() {
                environment[CmdsEnv.supportDirectory] = supportDirectory
            }
            let config = TerminalLaunchConfig(workingDirectory: cwd, command: command, environment: environment)
            pane = Pane(id: id, workspaceID: workspace.id, terminal: TerminalEngineProvider.shared.makeSurface(config: config))
            if pane.workingDirectory == nil { pane.workingDirectory = cwd }
        case .browser:
            let browser = BrowserPane()
            pane = Pane(id: id, workspaceID: workspace.id, browser: browser)
            if let url, !url.isEmpty { browser.navigate(to: url) } else { browser.showStartPage() }
        }
        pane.controller = self
        workspace.panes[id] = pane
        return pane
    }

    private func applyFocus(_ pane: Pane, in workspace: Workspace) {
        workspace.focusedPaneID = pane.id
        if let zoomed = workspace.zoomedPaneID, zoomed != pane.id { workspace.zoomedPaneID = nil }
        if pane.kind == .terminal, let cwd = pane.workingDirectory, cwd != workspace.workingDirectory {
            workspace.workingDirectory = cwd
            workspace.gitBranch = GitInfo.branch(at: cwd)
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

    private func resolveWorkspace(_ id: String?) throws -> Workspace {
        if let id {
            guard let workspace = workspace(id: id) else { throw RPCError.notFound("workspace not found: \(id)") }
            return workspace
        }
        guard let workspace = selectedWorkspace else { throw RPCError.notFound("no workspace") }
        return workspace
    }

    private func resolvePane(_ id: String?) throws -> Pane {
        if let id {
            guard let pane = pane(id: id) else { throw RPCError.notFound("pane not found: \(id)") }
            return pane
        }
        guard let pane = focusedPane else { throw RPCError.notFound("no focused pane") }
        return pane
    }

    private func terminal(for paneID: String?) throws -> TerminalSurface {
        let pane = try resolvePane(paneID)
        guard let terminal = pane.terminal else { throw RPCError.invalidParams("pane \(pane.id) is not a terminal") }
        return terminal
    }

    private func emit(_ change: StateChange) {
        subject.send(change)
        var userInfo: [String: Any] = ["change": change]
        if let id = change.workspaceID { userInfo["workspaceID"] = id }
        if let id = change.paneID { userInfo["paneID"] = id }
        NotificationCenter.default.post(name: .cmdsStateDidChange, object: self, userInfo: userInfo)
        scheduleSave()
    }

    private func scheduleSave() {
        guard saveWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveSession() }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
