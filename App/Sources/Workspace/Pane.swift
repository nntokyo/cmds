import AppKit
import CmdsCore

/// One pane of a workspace: a terminal surface, a browser or a file preview, hosted in a `PaneContainerView`.
@MainActor
final class Pane {
    let id: String
    let workspaceID: String
    let kind: PaneKind
    /// nil for browsers, and for an SSH pane restored from the session until the user connects it.
    private(set) var terminal: TerminalSurface?
    let browser: BrowserPane?
    /// Set for preview panes (a local file).
    let preview: PreviewPane?
    /// Set for SSH panes (docs/SSH.md); `workingDirectory` is then a path on the remote host.
    let ssh: SSHSession?
    let container: PaneContainerView

    var title: String
    var workingDirectory: String?
    private(set) var attention = false
    private(set) var attentionDate: Date?
    /// Set while the app tears the pane down, so surface close callbacks are ignored.
    var isClosing = false
    /// Usage of the coding agent running here (Claude Code via `agent.report`, Codex from its session file).
    var agentUsage: AgentUsage?
    var agentSource: AgentSource?

    // Resuming agent sessions (AppController+AgentSessions.swift, docs/AGENTS.md "Resuming sessions").
    /// The resumable agent session that ran here last (Claude Code / Codex with a session id). Saved in the session.
    var agentSession: AgentSession?
    /// A session from the previous run (or from before an SSH disconnect) offered for resuming.
    var resumeOffer: AgentSession?
    /// Resume was requested (button, `agent.resume`, mode Always): typed once the shell prompt is ready.
    var resumeRequestedAt: Date?
    /// Session typed into this pane in this run (never typed twice).
    var resumedSessionID: String?
    /// Readiness check: the screen text and since when it has not changed.
    var resumeScreen: String?
    var resumeScreenSince: Date?
    /// When the pane's terminal was created (the shell needs a moment to print its prompt).
    var terminalStartedAt = Date()
    /// Last `remote.location` from the remote shell's prompt hook (SSH panes).
    var lastPromptReportAt: Date?
    /// The lastSeen of `agentSession` as last saved, to save again only now and then.
    var agentSessionSavedAt: Date?

    weak var controller: AppController?

    init(id: String, workspaceID: String, terminal: TerminalSurface, ssh: SSHSession? = nil) {
        self.id = id
        self.workspaceID = workspaceID
        kind = .terminal
        self.terminal = terminal
        browser = nil
        preview = nil
        self.ssh = ssh
        title = ssh.map { $0.launch.label } ?? (terminal.title.isEmpty ? "Terminal" : terminal.title)
        workingDirectory = ssh == nil ? terminal.workingDirectory : ssh?.launch.remoteCwd
        container = PaneContainerView(paneID: id, content: terminal.view)
        terminal.delegate = self
    }

    /// An SSH pane without a terminal yet (restored from the session; connects when the user asks).
    init(id: String, workspaceID: String, ssh: SSHSession) {
        self.id = id
        self.workspaceID = workspaceID
        kind = .terminal
        terminal = nil
        browser = nil
        preview = nil
        self.ssh = ssh
        title = ssh.launch.label
        workingDirectory = ssh.launch.remoteCwd
        let placeholder = NSView()
        placeholder.wantsLayer = true
        placeholder.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        container = PaneContainerView(paneID: id, content: placeholder)
    }

    /// Replaces the terminal surface (SSH reconnect); the old one is closed without close callbacks.
    func attach(terminal newTerminal: TerminalSurface) {
        if let old = terminal {
            old.delegate = nil
            old.close()
        }
        terminal = newTerminal
        terminalStartedAt = Date()
        resumeScreen = nil
        resumeScreenSince = nil
        newTerminal.delegate = self
        container.setContent(newTerminal.view)
    }

    /// Shows or hides the SSH overlay (Disconnected / Not connected).
    func setSSHOverlay(_ state: SSHOverlayView.State?) {
        guard let state, let ssh else {
            container.setOverlay(nil)
            return
        }
        let overlay = SSHOverlayView(host: ssh.launch.host, state: state)
        overlay.onReconnect = { [weak self] in
            guard let self else { return }
            try? self.controller?.connectSSH(paneID: self.id)
        }
        overlay.onClose = { [weak self] in
            guard let self else { return }
            try? self.controller?.closePane(id: self.id)
        }
        overlay.onFocus = { [weak self] in
            guard let self else { return }
            self.controller?.paneDidBecomeFocused(self)
        }
        container.setOverlay(overlay)
    }

    var remoteInfo: RemoteInfo? {
        ssh.map { RemoteInfo(host: $0.launch.host, connected: $0.connected, branch: $0.remoteBranch) }
    }

    init(id: String, workspaceID: String, browser: BrowserPane) {
        self.id = id
        self.workspaceID = workspaceID
        kind = .browser
        terminal = nil
        ssh = nil
        preview = nil
        self.browser = browser
        title = "Browser"
        container = PaneContainerView(paneID: id, content: browser)
        browser.onStateChange = { [weak self] in
            guard let self else { return }
            self.title = browser.pageTitle.isEmpty ? (browser.currentURL?.host ?? "Browser") : browser.pageTitle
            self.controller?.paneDidChange(self)
        }
        browser.onFocus = { [weak self] in
            guard let self else { return }
            self.controller?.paneDidBecomeFocused(self)
        }
    }

    init(id: String, workspaceID: String, preview: PreviewPane) {
        self.id = id
        self.workspaceID = workspaceID
        kind = .preview
        terminal = nil
        ssh = nil
        browser = nil
        self.preview = preview
        title = preview.fileName
        container = PaneContainerView(paneID: id, content: preview)
        preview.onStateChange = { [weak self] in
            guard let self else { return }
            self.title = preview.fileName
            self.controller?.paneDidChange(self)
        }
    }

    var url: String? { browser?.currentURL?.absoluteString }

    func focus() {
        if let overlay = container.overlay, let window = overlay.window {
            window.makeFirstResponder(overlay)
        } else if let terminal {
            terminal.focus()
        } else if let preview {
            preview.focus()
        } else {
            browser?.focus()
        }
    }

    func setAttention(_ lit: Bool) {
        attention = lit
        attentionDate = lit ? Date() : nil
        container.attention = lit
    }

    func info(focused: Bool) -> PaneInfo {
        PaneInfo(id: id, kind: kind, title: title, focused: focused, attention: attention,
                 workingDirectory: workingDirectory, url: url, agent: agentUsage, remote: remoteInfo,
                 file: preview?.path)
    }

    /// Releases the underlying surface without triggering `terminalSurfaceDidClose` handling.
    func tearDown() {
        isClosing = true
        container.removeFromSuperview()
        if let terminal {
            terminal.delegate = nil
            terminal.close()
        }
        browser?.tearDown()
        preview?.tearDown()
        ssh?.stopAPI()
    }
}

extension Pane: TerminalSurfaceDelegate {
    func terminalSurface(_ surface: TerminalSurface, didChangeTitle title: String) {
        guard surface === terminal, !title.isEmpty, title != self.title else { return }
        self.title = title
        controller?.paneDidChange(self)
    }

    func terminalSurface(_ surface: TerminalSurface, didChangeWorkingDirectory path: String) {
        guard surface === terminal, path != workingDirectory else { return }
        // OSC 7 from a remote shell must say `localhost` (libghostty drops other hosts); the path is remote.
        if ssh != nil, ssh?.remoteBranch != nil { ssh?.remoteBranch = nil }
        workingDirectory = path
        controller?.paneDidChangeWorkingDirectory(self)
    }

    func terminalSurfaceDidRingBell(_ surface: TerminalSurface) {
        controller?.raiseAttention(pane: self, title: nil, body: String(localized: "Bell"))
    }

    func terminalSurface(_ surface: TerminalSurface, didPostNotification title: String, body: String) {
        controller?.raiseAttention(pane: self, title: title.isEmpty ? nil : title, body: body)
    }

    func terminalSurfaceDidBecomeFocused(_ surface: TerminalSurface) {
        controller?.paneDidBecomeFocused(self)
    }

    func terminalSurfaceDidClose(_ surface: TerminalSurface) {
        guard !isClosing, surface === terminal else { return }
        if ssh != nil {
            // An SSH pane stays (with its overlay) until the user closes it.
            controller?.sshDidDisconnect(self)
            return
        }
        controller?.surfaceDidClose(self)
    }

    /// ⌘-click on a file path opens it in a preview pane; URLs, folders and missing files keep the default
    /// (open with the default app / Finder).
    func terminalSurface(_ surface: TerminalSurface, openLink link: String) -> Bool {
        guard surface === terminal, let path = Self.localPath(fromLink: link, relativeTo: workingDirectory) else {
            return false
        }
        if ssh != nil {
            // A path printed on the server: there is no such file here (and opening a same-named local one would
            // show the wrong file).
            NSSound.beep()
            return true
        }
        guard let file = Self.existingFile(path) else { return false }
        controller?.openFileFromTerminal(self, path: file)
        return true
    }

    /// `file://…`, `/abs`, `~/…` or a relative path (against `cwd`); nil for URLs with another scheme.
    static func localPath(fromLink link: String, relativeTo cwd: String?) -> String? {
        if link.hasPrefix("file:") {
            guard let url = URL(string: link), url.isFileURL else { return nil }
            return url.path
        }
        if link.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil { return nil }
        let expanded = (link as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
        guard let cwd else { return nil }
        return ((cwd as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }

    /// The path if it is an existing file, else the path without a `:line[:column]` suffix (compiler output).
    static func existingFile(_ path: String) -> String? {
        var candidates = [path]
        if let range = path.range(of: #":\d+(:\d+)?:?$"#, options: .regularExpression) {
            candidates.append(String(path[..<range.lowerBound]))
        }
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    func terminalSurfaceChildDidExit(_ surface: TerminalSurface) {
        guard !isClosing, surface === terminal, ssh != nil else { return }
        controller?.sshDidDisconnect(self)
    }
}
