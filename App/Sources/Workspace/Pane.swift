import AppKit
import CmdsCore

/// One pane of a workspace: a terminal surface or a browser, hosted in a `PaneContainerView`.
@MainActor
final class Pane {
    let id: String
    let workspaceID: String
    let kind: PaneKind
    let terminal: TerminalSurface?
    let browser: BrowserPane?
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

    weak var controller: AppController?

    init(id: String, workspaceID: String, terminal: TerminalSurface) {
        self.id = id
        self.workspaceID = workspaceID
        kind = .terminal
        self.terminal = terminal
        browser = nil
        title = terminal.title.isEmpty ? "Terminal" : terminal.title
        workingDirectory = terminal.workingDirectory
        container = PaneContainerView(paneID: id, content: terminal.view)
        terminal.delegate = self
    }

    init(id: String, workspaceID: String, browser: BrowserPane) {
        self.id = id
        self.workspaceID = workspaceID
        kind = .browser
        terminal = nil
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

    var url: String? { browser?.currentURL?.absoluteString }

    func focus() {
        if let terminal { terminal.focus() } else { browser?.focus() }
    }

    func setAttention(_ lit: Bool) {
        attention = lit
        attentionDate = lit ? Date() : nil
        container.attention = lit
    }

    func info(focused: Bool) -> PaneInfo {
        PaneInfo(id: id, kind: kind, title: title, focused: focused, attention: attention,
                 workingDirectory: workingDirectory, url: url, agent: agentUsage)
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
    }
}

extension Pane: TerminalSurfaceDelegate {
    func terminalSurface(_ surface: TerminalSurface, didChangeTitle title: String) {
        guard !title.isEmpty, title != self.title else { return }
        self.title = title
        controller?.paneDidChange(self)
    }

    func terminalSurface(_ surface: TerminalSurface, didChangeWorkingDirectory path: String) {
        guard path != workingDirectory else { return }
        workingDirectory = path
        controller?.paneDidChangeWorkingDirectory(self)
    }

    func terminalSurfaceDidRingBell(_ surface: TerminalSurface) {
        controller?.raiseAttention(pane: self, title: nil, body: "Bell")
    }

    func terminalSurface(_ surface: TerminalSurface, didPostNotification title: String, body: String) {
        controller?.raiseAttention(pane: self, title: title.isEmpty ? nil : title, body: body)
    }

    func terminalSurfaceDidBecomeFocused(_ surface: TerminalSurface) {
        controller?.paneDidBecomeFocused(self)
    }

    func terminalSurfaceDidClose(_ surface: TerminalSurface) {
        guard !isClosing else { return }
        controller?.surfaceDidClose(self)
    }
}
