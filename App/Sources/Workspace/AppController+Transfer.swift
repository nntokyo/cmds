import AppKit
import CmdsCore

/// Moving workspaces and their agent sessions between cmds instances (`state.export` / `state.import`,
/// File › Export Workspaces… / Import Workspaces…; docs/guide/ai-agents.md "Moving to a new version").
///
/// Export is the session state (`sessionState()`, the same data session.json keeps) as a `WorkspaceBundle`.
/// Import validates the bundle, recreates its workspaces after the existing ones (or instead of them) the way a
/// relaunch restores session.json, and gives each pane its agent session as resume offer: Ask shows the banner,
/// Always queues it for when the shell prompt is ready, Never registers nothing.
extension AppController {
    func exportBundle() throws -> WorkspaceBundle {
        let state = sessionState()
        func convert(_ node: SessionState.Node, sessions: [Int: AgentSession], next: inout Int) -> WorkspaceBundle.Node {
            switch node {
            case .split(let axis, let ratio, let first, let second):
                let a = convert(first, sessions: sessions, next: &next)
                let b = convert(second, sessions: sessions, next: &next)
                return .split(axis: axis, ratio: ratio.isFinite ? ratio : 0.5, first: a, second: b)
            case .terminal(let cwd):
                defer { next += 1 }
                return .pane(.terminal(cwd: cwd, session: sessions[next]))
            case .ssh(let host, let remoteCwd):
                defer { next += 1 }
                return .pane(.ssh(host: host, remoteCwd: remoteCwd, session: sessions[next]))
            case .browser(let url):
                defer { next += 1 }
                return .pane(WorkspaceBundle.Pane(kind: .browser, url: url.flatMap(WorkspaceBundle.portableURL)))
            case .preview(let path, let format):
                defer { next += 1 }
                return .pane(WorkspaceBundle.Pane(kind: .preview, path: path, format: format))
            }
        }
        let workspaces = state.workspaces.map { saved -> WorkspaceBundle.Workspace in
            let sessions = Dictionary((saved.agentSessions ?? []).map { ($0.paneIndex, $0.session) }) { first, _ in first }
            var next = 0
            let layout = convert(saved.layout, sessions: sessions, next: &next)
            return WorkspaceBundle.Workspace(title: saved.title, workingDirectory: saved.workingDirectory,
                                             focusedPaneIndex: saved.focusedPaneIndex.flatMap { $0 < next ? $0 : nil },
                                             layout: layout)
        }
        let info = Bundle.main.infoDictionary ?? [:]
        let bundle = WorkspaceBundle(
            workspaces: workspaces,
            selectedIndex: state.selectedIndex.flatMap { workspaces.indices.contains($0) ? $0 : nil },
            source: .init(version: info["CFBundleShortVersionString"] as? String, build: info["CFBundleVersion"] as? String))
        do {
            return try bundle.validated()
        } catch let error as TransferError {
            throw RPCError(code: 500, message: "cannot export: \(error.message)")
        }
    }

    /// Recreates the (validated) bundle's workspaces. `resume` nil = the app's setting (View › Resume Agent Sessions
    /// on Launch).
    @discardableResult
    func importBundle(_ bundle: WorkspaceBundle, mode: ImportMode = .append, resume: AgentResumeMode? = nil) -> ImportResult {
        let resumeMode = resume ?? AgentResumeSettings.mode
        let previous = workspaces.map(\.id)
        let created = restoreWorkspaces(SessionState(bundle: bundle), resumeMode: resumeMode)
        var closed = 0
        if mode == .replace {
            for id in previous where (try? closeWorkspace(id: id)) != nil { closed += 1 }
        }
        if let selected = created[safe: bundle.selectedIndex ?? 0] ?? created.first {
            try? selectWorkspace(id: selected.id)
        }
        emit(.workspaces)
        var offers: [ImportResult.Offer] = []
        for workspace in created {
            for pane in workspace.orderedPanes {
                guard let offer = pane.resumeOffer else { continue }
                offers.append(.init(workspace: workspace.id, pane: pane.id, agent: offer.agent, sessionID: offer.sessionID,
                                    command: AgentResume.command(for: offer)))
            }
        }
        return ImportResult(workspaces: created.map(\.id), panes: created.reduce(0) { $0 + $1.panes.count },
                            closed: closed, resume: resumeMode, offers: offers)
    }
}

extension SessionState {
    /// The bundle as a session to restore. Local `~` paths are expanded (remote ones are left to the server's shell).
    init(bundle: WorkspaceBundle) {
        func local(_ path: String?) -> String? { path.map { ($0 as NSString).expandingTildeInPath } }
        func node(_ value: WorkspaceBundle.Node, sessions: inout [PaneAgentSession], next: inout Int) -> Node {
            switch value {
            case .split(let axis, let ratio, let first, let second):
                let a = node(first, sessions: &sessions, next: &next)
                let b = node(second, sessions: &sessions, next: &next)
                return .split(axis: axis, ratio: ratio, first: a, second: b)
            case .pane(let pane):
                defer { next += 1 }
                if let session = pane.agentSession { sessions.append(PaneAgentSession(paneIndex: next, session: session)) }
                switch pane.kind {
                case .terminal:
                    if let host = pane.host { return .ssh(host: host, remoteCwd: pane.remoteCwd) }
                    return .terminal(cwd: local(pane.cwd))
                case .browser:
                    return .browser(url: pane.url)
                case .preview:
                    return .preview(path: pane.path ?? NSHomeDirectory(), format: pane.format)
                }
            }
        }
        workspaces = bundle.workspaces.map { workspace in
            var sessions: [PaneAgentSession] = []
            var next = 0
            let layout = node(workspace.layout, sessions: &sessions, next: &next)
            let isRemote = workspace.panes[safe: workspace.focusedPaneIndex ?? 0]?.host != nil
            return WorkspaceState(title: workspace.title,
                                  workingDirectory: isRemote ? workspace.workingDirectory : local(workspace.workingDirectory),
                                  layout: layout, focusedPaneIndex: workspace.focusedPaneIndex,
                                  agentSessions: sessions.isEmpty ? nil : sessions)
        }
        selectedIndex = bundle.selectedIndex
    }
}
