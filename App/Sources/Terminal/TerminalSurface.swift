import AppKit

/// Contract between the app shell (workspaces, panes) and the terminal engine.
/// The engine is libghostty (`Terminal/Ghostty/`); the shell must only use this file's API.

struct TerminalLaunchConfig {
    var workingDirectory: String?
    /// Command to run instead of the user's login shell.
    var command: String?
    /// Extra environment (CMDS_* variables are added here by the shell).
    var environment: [String: String] = [:]
    /// Keep the surface (and its last screen) when the command exits and report `terminalSurfaceChildDidExit`
    /// instead of closing (SSH panes show a Reconnect overlay).
    var waitAfterCommand = false
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
    /// Only for surfaces launched with `waitAfterCommand`: the command exited; the surface stays open.
    func terminalSurfaceChildDidExit(_ surface: TerminalSurface)
}

extension TerminalSurfaceDelegate {
    func terminalSurfaceChildDidExit(_ surface: TerminalSurface) {}
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
    /// Like `sendText`, but printable text arrives as typed keystrokes (never as a bracketed paste).
    func typeText(_ text: String)
    /// Makes the terminal the first responder.
    func focus()
    /// Plain text of the visible screen (rows joined by "\n").
    func visibleText() -> String
    /// Cursor cell, 0-based: `row` indexes the lines of `visibleText()`, `col` counts cells
    /// (a wide character occupies two). nil if unknown or scrolled out of view.
    var cursorPosition: (row: Int, col: Int)? { get }
    /// Terminal grid size in cells; nil if unknown.
    var gridSize: (rows: Int, cols: Int)? { get }
    /// Foreground process group of the terminal's pty (the shell itself while idle); nil if unknown.
    /// The app maps it to the pty's tty to find every process running in the pane (CPU/memory, ports):
    /// macOS hides the environment of Apple platform binaries such as /bin/zsh, so CMDS_* is not enough.
    var foregroundProcessGroupID: pid_t? { get }
    /// Plain text of scrollback + screen, capped to `maxLines` from the bottom.
    func scrollbackText(maxLines: Int) -> String
    func close()
}

@MainActor
protocol TerminalEngine: AnyObject {
    func makeSurface(config: TerminalLaunchConfig) -> TerminalSurface
}
