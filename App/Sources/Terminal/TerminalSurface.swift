import AppKit

/// Contract between the app shell (workspaces, panes) and the terminal engine.
/// The engine is libghostty (`Terminal/Ghostty/`); the shell must only use this file's API.

struct TerminalLaunchConfig {
    var workingDirectory: String?
    /// Command to run instead of the user's login shell.
    var command: String?
    /// Extra environment (CMDS_* variables are added here by the shell).
    var environment: [String: String] = [:]
}

@MainActor
protocol TerminalSurfaceDelegate: AnyObject {
    func terminalSurface(_ surface: TerminalSurface, didChangeTitle title: String)
    func terminalSurface(_ surface: TerminalSurface, didChangeWorkingDirectory path: String)
    func terminalSurfaceDidRingBell(_ surface: TerminalSurface)
    /// OSC 9 / OSC 777 desktop notification from the program running in the terminal.
    func terminalSurface(_ surface: TerminalSurface, didPostNotification title: String, body: String)
    func terminalSurfaceDidBecomeFocused(_ surface: TerminalSurface)
    /// The child process exited or the surface requested to close.
    func terminalSurfaceDidClose(_ surface: TerminalSurface)
}

@MainActor
protocol TerminalSurface: AnyObject {
    var delegate: TerminalSurfaceDelegate? { get set }
    /// The view to embed in a pane. Owned by the surface.
    var view: NSView { get }
    var title: String { get }
    var workingDirectory: String? { get }

    /// Types text as if pasted/typed by the user (no bracketed paste for "\n").
    func sendText(_ text: String)
    /// Makes the terminal the first responder.
    func focus()
    /// Plain text of the visible screen (rows joined by "\n").
    func visibleText() -> String
    /// Plain text of scrollback + screen, capped to `maxLines` from the bottom.
    func scrollbackText(maxLines: Int) -> String
    func close()
}

@MainActor
protocol TerminalEngine: AnyObject {
    func makeSurface(config: TerminalLaunchConfig) -> TerminalSurface
}
