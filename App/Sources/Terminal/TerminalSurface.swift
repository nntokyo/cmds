import AppKit
import CmdsCore

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
    /// The user ⌘-clicked a link or file path (`link` as detected by the engine: a URL, or a path that the engine
    /// already resolved against the shell's directory when the file exists). Return true when handled; false lets
    /// the engine open it with the default app.
    func terminalSurface(_ surface: TerminalSurface, openLink link: String) -> Bool
    /// The user pressed a key that went to the terminal (not for text sent through the API).
    func terminalSurfaceDidReceiveKeyInput(_ surface: TerminalSurface)
    /// A key binding of the user's terminal config asked for the search UI (libghostty's `start_search`,
    /// `search_selection`); `needle` is the text to search for, if any.
    func terminalSurface(_ surface: TerminalSurface, didRequestSearch needle: String?)
    /// libghostty's search counted its hits (`total`, nil while unknown) or selected one (`selected`: 0 is the first
    /// one selected, at the bottom; nil when none is).
    func terminalSurface(_ surface: TerminalSurface, searchDidUpdate total: Int?, selected: Int?)
}

extension TerminalSurfaceDelegate {
    func terminalSurfaceChildDidExit(_ surface: TerminalSurface) {}
    func terminalSurfaceDidReceiveKeyInput(_ surface: TerminalSurface) {}
    func terminalSurface(_ surface: TerminalSurface, openLink link: String) -> Bool { false }
    func terminalSurface(_ surface: TerminalSurface, didRequestSearch needle: String?) {}
    func terminalSurface(_ surface: TerminalSurface, searchDidUpdate total: Int?, selected: Int?) {}
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
    /// The visible screen row by row with each row's colours and attributes (`StyleRun`, columns as the phone's grid
    /// counts them); the rows' text is `visibleText()`'s, except for trailing spaces where styled blank cells are. nil
    /// when the engine cannot read styles.
    func visibleStyledRows() -> [StyledRow]?
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
    /// Where the viewport is in the whole screen (history + active area), read now; nil if unknown. (`TerminalScrollbar`
    /// is in CmdsCore, which unit-tests the sync stream's arithmetic on it.)
    func scrollbar() -> TerminalScrollbar?
    /// Up to `maxRows` rows above the viewport, oldest first; the last one is the row right above the first line of
    /// `visibleText()`. One entry per displayed row as in `visibleText()` (soft wraps not joined). Reads only those
    /// rows and never moves the viewport; while it is scrolled up, these are the rows above what it shows. Empty when
    /// there are none (alternate screen, e.g. vim); nil when the `scrollbar()` changed during the read (output, rows
    /// pruned past the scrollback limit): ask again.
    func historyRows(maxRows: Int) -> [String]?
    /// `historyRows` with each row's colours and attributes, as `visibleStyledRows` reads the screen's.
    func historyStyledRows(maxRows: Int) -> [StyledRow]?
    func close()

    // MARK: Search (⌘F, TerminalFind)

    /// Starts or changes the engine's own search (libghostty: plain text, ASCII case-insensitive, on its own thread):
    /// it highlights every hit, selects one and scrolls to it, and reports `searchDidUpdate`. "" stops searching.
    func search(_ needle: String)
    /// Selects the next hit (`next`, going up towards older output) or the previous one and scrolls to it.
    func navigateSearch(next: Bool)
    /// Ends the engine's search and removes its highlights.
    func endSearch()
    /// Rows `range` of the whole screen (0 is the top of the history, `scrollbar().total` rows), one entry per
    /// displayed row as `historyRows` reads them; nil when a row could not be read.
    func screenRows(_ range: Range<Int>) -> [String]?
    /// Rows `rows` of the whole screen (as in `screenRows`) read as one selection, the way copying them reads: lines
    /// that wrapped joined, rows ended with "\n", blank rows at the end left out. `ansi`: with the SGR sequences of
    /// their colours and attributes (`ghostty_surface_read_text_vt`). nil when they could not be read. Pane › Export
    /// Scrollback reads the history in such chunks (`ScrollbackExport.Job`, #253).
    func screenText(_ rows: ClosedRange<Int>, ansi: Bool) -> String?
    /// Scrolls so that screen row `row` (as in `screenRows`) is the top row of the viewport, or as close as it goes.
    func scroll(toRow row: Int)
    /// Where `width` cells from `column` of viewport row `row` are, in `view`'s coordinates; nil if unknown.
    func cellRect(viewportRow row: Int, column: Int, width: Int) -> NSRect?
    /// While set, the terminal does not take the keyboard (the find bar is open): it refuses first responder, and
    /// clicks and `focus()` focus this view instead.
    var keyboardRedirect: NSView? { get set }
}

@MainActor
protocol TerminalEngine: AnyObject {
    func makeSurface(config: TerminalLaunchConfig) -> TerminalSurface
}
