import AppKit
import CmdsCore
import GhosttyKit

/// libghostty-backed terminal engine. All surfaces share one `ghostty_app_t` (`GhosttyRuntime`).
@MainActor
final class GhosttyTerminalEngine: TerminalEngine {
    init() {}

    func makeSurface(config: TerminalLaunchConfig) -> TerminalSurface {
        guard let app = GhosttyRuntime.shared.app else {
            return FallbackSurface(config: config, message: "libghostty failed to initialize")
        }
        let surface = GhosttyTerminalSurface(app: app, config: config)
        if (surface.view as? GhosttySurfaceView)?.surface == nil {
            return FallbackSurface(config: config, message: "ghostty_surface_new failed")
        }
        return surface
    }
}

@MainActor
final class GhosttyTerminalSurface: TerminalSurface {
    weak var delegate: TerminalSurfaceDelegate?
    private let surfaceView: GhosttySurfaceView
    var view: NSView { surfaceView }
    private(set) var title: String
    private(set) var workingDirectory: String?
    private var closed = false

    init(app: ghostty_app_t, config: TerminalLaunchConfig) {
        surfaceView = GhosttySurfaceView(app: app, config: config)
        workingDirectory = config.workingDirectory
        if let cmd = config.command, let first = cmd.split(separator: " ").first {
            title = (String(first) as NSString).lastPathComponent
        } else {
            title = ((ProcessInfo.processInfo.environment["SHELL"] ?? "shell") as NSString).lastPathComponent
        }
        surfaceView.owner = self
    }

    deinit {
        let v = surfaceView
        if Thread.isMainThread {
            MainActor.assumeIsolated { v.teardown() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { v.teardown() } }
        }
    }

    // MARK: TerminalSurface

    func sendText(_ text: String) {
        surfaceView.sendText(text)
    }

    func typeText(_ text: String) {
        surfaceView.typeText(text)
    }

    var gridSize: (rows: Int, cols: Int)? {
        guard let surface = surfaceView.surface else { return nil }
        let size = ghostty_surface_size(surface)
        guard size.rows > 0, size.columns > 0 else { return nil }
        return (Int(size.rows), Int(size.columns))
    }

    var foregroundProcessGroupID: pid_t? {
        guard let surface = surfaceView.surface else { return nil }
        let pgid = ghostty_surface_foreground_pid(surface) // tcgetpgrp of the pty, 0 when unknown
        guard pgid > 0, pgid <= UInt64(Int32.max) else { return nil }
        return pid_t(pgid)
    }

    func focus() {
        guard let window = surfaceView.window else { return }
        window.makeFirstResponder(surfaceView)
    }

    /// One line per viewport row (soft-wrapped rows are NOT joined, so line N is screen row N and
    /// matches `cursorPosition.row`). Blank cells before text become spaces; trailing blanks are dropped.
    /// Rows are read one by one, so a snapshot taken during heavy output may mix two adjacent frames.
    func visibleText() -> String {
        guard let surface = surfaceView.surface else { return "" }
        let size = ghostty_surface_size(surface)
        let rows = Int(size.rows), cols = Int(size.columns)
        guard rows > 0, cols > 0 else { return "" }
        return (0..<rows).map { readRow(surface, GHOSTTY_POINT_VIEWPORT, $0, cols: cols) ?? "" }.joined(separator: "\n")
    }

    /// `visibleText()`'s rows read as VT text (`ghostty_surface_read_text_vt`, from cmds' libghostty patch: SGR with
    /// palette indexes, CUF over blank cells) and split into text and style runs by `TerminalStyledText` (CmdsCore).
    /// One read per row like `visibleText()`, plus the parsing; only the sync server asks, for phones that draw colours.
    func visibleStyledRows() -> [(text: String, runs: [StyleRun])]? {
        guard let surface = surfaceView.surface else { return nil }
        let size = ghostty_surface_size(surface)
        let rows = Int(size.rows), cols = Int(size.columns)
        guard rows > 0, cols > 0 else { return [] }
        return (0..<rows).map { row in
            TerminalStyledText.parse(readRowVT(surface, GHOSTTY_POINT_VIEWPORT, row, cols: cols) ?? "")
        }
    }

    /// `ghostty_surface_scrollbar`, from cmds' libghostty patch (vendor/ghostty-patches): the same figures as the
    /// renderer's scrollbar action, but read now, so they are current while the surface is not drawn too, plus the
    /// rows pruned so far (`PageList.pruned_rows`).
    func scrollbar() -> TerminalScrollbar? {
        guard let surface = surfaceView.surface else { return nil }
        let bar = ghostty_surface_scrollbar(surface)
        guard bar.len > 0 else { return nil }
        return TerminalScrollbar(total: Int(clamping: bar.total), offset: Int(clamping: bar.offset),
                                 rows: Int(clamping: bar.len), pruned: Int(clamping: bar.pruned))
    }

    /// The rows are read by their screen row, as `visibleText()` reads the viewport's: with cmds' libghostty patch,
    /// exact `GHOSTTY_POINT_SCREEN` points reach the whole history (upstream clamps every point to the viewport
    /// height). Only those rows are read: the history can be megabytes, and reading compressed pages inflates them
    /// again.
    func historyRows(maxRows: Int) -> [String]? {
        guard maxRows > 0, let surface = surfaceView.surface, let bar = scrollbar() else { return [] }
        let cols = Int(ghostty_surface_size(surface).columns)
        guard cols > 0, bar.offset > 0 else { return [] }
        var lines: [String] = []
        lines.reserveCapacity(min(maxRows, bar.offset))
        for row in max(0, bar.offset - maxRows)..<bar.offset {
            guard let line = readRow(surface, GHOSTTY_POINT_SCREEN, row, cols: cols) else { return nil }
            lines.append(line)
        }
        // New rows alone would not matter (screen rows count from the top of the history), but rows pruned past the
        // scrollback limit or a cleared history shift them, and a scrolled viewport has others above it.
        return scrollbar() == bar ? lines : nil
    }

    func scrollbackText(maxLines: Int) -> String {
        guard maxLines > 0, let surface = surfaceView.surface else { return "" }
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        let all = read(surface, sel)?.text ?? ""
        var lines = all.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty, lines.count > 1 {
            lines.removeLast()
        }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    /// Exact cursor cell in the viewport. libghostty has no direct cursor query, so this combines:
    /// - `ghostty_surface_ime_point`: x = (col·cw + padL + cw/2)/s, y = (activeRow·ch + padT + ch)/s, h = ch/s
    /// - `ghostty_surface_read_text` tl_px of a cell: x = (col·cw + padL)/s, y = (viewRow·ch + ch − baseline + padT)/s
    /// Differencing against the viewport's (0,0) cell cancels padding and scale; the leftover baseline
    /// offset is < one cell, so flooring yields the active-area row. That cell is then read back to get
    /// its viewport row (differs from the active row when scrolled back; nil when off-screen).
    /// Cursor visibility (DECTCEM) is not exposed by libghostty, so a hidden cursor still reports a position.
    var cursorPosition: (row: Int, col: Int)? {
        guard let surface = surfaceView.surface else { return nil }
        let size = ghostty_surface_size(surface)
        let rows = Int(size.rows), cols = Int(size.columns)
        let cellW = Double(size.cell_width_px), cellH = Double(size.cell_height_px)
        guard rows > 0, cols > 0, cellW > 0, cellH > 0 else { return nil }

        let origin = ghostty_selection_s(
            top_left: Self.cell(GHOSTTY_POINT_VIEWPORT, col: 0, row: 0),
            bottom_right: Self.cell(GHOSTTY_POINT_VIEWPORT, col: 0, row: 0),
            rectangle: false)
        guard let o = read(surface, origin), o.y >= 0 else { return nil }

        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        guard h > 0 else { return nil }
        let scale = cellH / h  // points → pixels

        let col = min(max(Int(((x - o.x) * scale / cellW - 0.5).rounded()), 0), cols - 1)
        let activeRow = Int(((y - o.y) * scale / cellH + 1e-6).rounded(.down))
        guard (0..<rows).contains(activeRow) else { return nil }

        let cursorCell = ghostty_selection_s(
            top_left: Self.cell(GHOSTTY_POINT_ACTIVE, col: col, row: activeRow),
            bottom_right: Self.cell(GHOSTTY_POINT_ACTIVE, col: col, row: activeRow),
            rectangle: false)
        // tl_px is (-1, -1) when the cell is outside the viewport.
        guard let c = read(surface, cursorCell), c.y >= 0 else { return nil }
        let row = Int(((c.y - o.y) * scale / cellH).rounded())
        guard (0..<rows).contains(row) else { return nil }
        return (row, col)
    }

    func close() {
        guard !closed else { return }
        closed = true
        surfaceView.teardown()
        delegate?.terminalSurfaceDidClose(self)
    }

    // MARK: Text

    private static func cell(_ tag: ghostty_point_tag_e, col: Int, row: Int) -> ghostty_point_s {
        ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_EXACT, x: UInt32(max(col, 0)), y: UInt32(max(row, 0)))
    }

    /// Row `row` in `tag` coordinates (viewport, or screen = from the top of the history), nil when there is no such
    /// row. A single-row rectangle selection: libghostty's text reader always unwraps soft wraps, so rows are read
    /// separately; `rectangle` also stops a wide char that wrapped onto the next row from being pulled into this one.
    private func readRow(_ surface: ghostty_surface_t, _ tag: ghostty_point_tag_e, _ row: Int, cols: Int) -> String? {
        let sel = ghostty_selection_s(
            top_left: Self.cell(tag, col: 0, row: row),
            bottom_right: Self.cell(tag, col: cols - 1, row: row),
            rectangle: true)
        guard let text = read(surface, sel)?.text else { return nil }
        return text.contains("\n") ? text.replacingOccurrences(of: "\n", with: " ") : text
    }

    /// `readRow` as VT text: the row's text with the SGR sequences of its styles (`ghostty_surface_read_text_vt`).
    private func readRowVT(_ surface: ghostty_surface_t, _ tag: ghostty_point_tag_e, _ row: Int, cols: Int) -> String? {
        let sel = ghostty_selection_s(
            top_left: Self.cell(tag, col: 0, row: row),
            bottom_right: Self.cell(tag, col: cols - 1, row: row),
            rectangle: true)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text_vt(surface, sel, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return Self.string(from: text)
    }

    /// Reads a selection's text plus the viewport position (points) of its top-left cell; the position
    /// is (-1, -1) when the selection is not in the viewport. The returned text buffer is freed here.
    private func read(_ surface: ghostty_surface_t, _ sel: ghostty_selection_s) -> (text: String, x: Double, y: Double)? {
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, sel, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return (Self.string(from: text), text.tl_px_x, text.tl_px_y)
    }

    nonisolated static func string(from text: ghostty_text_s) -> String {
        guard let ptr = text.text, text.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(text.text_len)), as: UTF8.self)
    }

    // MARK: Events from GhosttyRuntime / GhosttySurfaceView
    // Delivered asynchronously on main so delegates never re-enter libghostty mid-callback.

    func handleTitle(_ newTitle: String) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.closed, self.title != newTitle else { return }
                self.title = newTitle
                self.delegate?.terminalSurface(self, didChangeTitle: newTitle)
            }
        }
    }

    func handlePwd(_ path: String) {
        // OSC 7 may deliver a file:// URL.
        let resolved: String
        if path.hasPrefix("file://"), let url = URL(string: path) {
            resolved = url.path
        } else {
            resolved = path
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.closed, self.workingDirectory != resolved else { return }
                self.workingDirectory = resolved
                self.delegate?.terminalSurface(self, didChangeWorkingDirectory: resolved)
            }
        }
    }

    func handleBell() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                self.delegate?.terminalSurfaceDidRingBell(self)
            }
        }
    }

    func handleNotification(title: String, body: String) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                self.delegate?.terminalSurface(self, didPostNotification: title, body: body)
            }
        }
    }

    func handleFocused() {
        guard !closed else { return }
        delegate?.terminalSurfaceDidBecomeFocused(self)
    }

    /// A key press from the user (called from `keyDown`, after it was handed to libghostty).
    func handleKeyInput() {
        guard !closed else { return }
        delegate?.terminalSurfaceDidReceiveKeyInput(self)
    }

    /// The command exited on a surface launched with `waitAfterCommand` (it stays open).
    func handleChildExited() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                self.delegate?.terminalSurfaceChildDidExit(self)
            }
        }
    }

    /// Child exited / libghostty asked to close: free the surface and tell the delegate.
    /// ⌘-click on a link (libghostty's link detection); true when the shell handled it.
    func handleOpenLink(_ link: String) -> Bool {
        guard !closed else { return false }
        return delegate?.terminalSurface(self, openLink: link) ?? false
    }

    func handleCloseRequest() {
        close()
    }
}

/// Shown only if libghostty cannot be initialized: a read-only text view with the error.
@MainActor
private final class FallbackSurface: TerminalSurface {
    weak var delegate: TerminalSurfaceDelegate?
    let view: NSView
    private let textView: NSTextView
    var title: String { "error" }
    let workingDirectory: String?

    init(config: TerminalLaunchConfig, message: String) {
        workingDirectory = config.workingDirectory
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = "cmds: \(message)\n"
        view = scroll
    }

    func sendText(_ text: String) {}
    func typeText(_ text: String) {}
    func focus() { view.window?.makeFirstResponder(textView) }
    func visibleText() -> String { textView.string }
    func visibleStyledRows() -> [(text: String, runs: [StyleRun])]? { nil }
    func scrollbackText(maxLines: Int) -> String { textView.string }
    func scrollbar() -> TerminalScrollbar? { nil }
    func historyRows(maxRows: Int) -> [String]? { [] } // `visibleText()` already has all of it
    var cursorPosition: (row: Int, col: Int)? { nil }
    var gridSize: (rows: Int, cols: Int)? { nil }
    var foregroundProcessGroupID: pid_t? { nil }
    func close() { delegate?.terminalSurfaceDidClose(self) }
}
