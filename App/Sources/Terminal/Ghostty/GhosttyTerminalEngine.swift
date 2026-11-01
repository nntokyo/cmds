import AppKit
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
        return (0..<rows).map { viewportRow(surface, $0, cols: cols) }.joined(separator: "\n")
    }

    /// libghostty's text API reaches exact rows only inside the viewport: `ghostty_surface_read_text` clamps every
    /// point to the viewport height, `GHOSTTY_POINT_SCREEN` ones too (apprt/embedded.zig `Point.pin`), and the
    /// scrollbar action comes from the renderer, which stops while the surface is hidden. So the viewport is moved
    /// over the wanted rows with `scroll_to_row`, they are read like `visibleText()` and the viewport is put back, all
    /// within this call on the main thread (about 1 ms for 1000 rows). Only those rows are read: the history can be
    /// megabytes, and reading compressed pages inflates them again. A pane on screen may draw one frame of the moved
    /// viewport (2 of 100 reads of 1000 rows did).
    func historyRows(maxRows: Int) -> [String] {
        guard maxRows > 0, let surface = surfaceView.surface else { return [] }
        let size = ghostty_surface_size(surface)
        let rows = Int(size.rows), cols = Int(size.columns)
        // Scrolled up by a screen or more, the viewport's place is unknown and could not be restored exactly.
        guard rows > 0, cols > 0, let lead = activeAreaRow(surface, cols: cols) else { return [] }
        guard let history = historyLength(surface, rows: rows, cols: cols) else {
            restoreViewport(lead: lead, top: nil)
            return []
        }
        let top = history - lead // the viewport's first row, counted from the top of the scrollback
        var lines: [String] = []
        lines.reserveCapacity(min(maxRows, top))
        var start = max(0, top - maxRows)
        while start < top {
            scrollViewport(toRow: start)
            let count = min(rows, top - start)
            for row in 0..<count { lines.append(viewportRow(surface, row, cols: cols)) }
            start += count
        }
        restoreViewport(lead: lead, top: top)
        return lines
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

    /// A single-row rectangle selection: libghostty's text reader always unwraps soft wraps, so rows are read
    /// separately; `rectangle` also stops a wide char that wrapped onto the next row from being pulled into this one.
    private func viewportRow(_ surface: ghostty_surface_t, _ row: Int, cols: Int) -> String {
        let sel = ghostty_selection_s(
            top_left: Self.cell(GHOSTTY_POINT_VIEWPORT, col: 0, row: row),
            bottom_right: Self.cell(GHOSTTY_POINT_VIEWPORT, col: cols - 1, row: row),
            rectangle: true)
        let text = read(surface, sel)?.text ?? ""
        return text.contains("\n") ? text.replacingOccurrences(of: "\n", with: " ") : text
    }

    /// Viewport row of the active area's first row (0 while the viewport follows the output), or nil when that row is
    /// below the viewport.
    private func activeAreaRow(_ surface: ghostty_surface_t, cols: Int) -> Int? {
        let cell = Self.cell(GHOSTTY_POINT_ACTIVE, col: 0, row: 0)
        guard let first = read(surface, ghostty_selection_s(top_left: cell, bottom_right: cell, rectangle: false)),
              first.y >= 0 else { return nil }
        return first.cell / cols
    }

    /// Rows above the active area, found by moving the viewport: after `scroll_to_row:p` the active area's first row
    /// is on viewport row H − p when 0 < H − p < rows, on row 0 when p ≥ H (the viewport stops at the active area)
    /// and below the viewport when H − p ≥ rows. Starts at the scrollbar's figure, which is exact while the surface is
    /// drawn, so one probe usually does. nil when the answers contradict each other (output arrived meanwhile).
    private func historyLength(_ surface: ghostty_surface_t, rows: Int, cols: Int) -> Int? {
        let maxProbe = 1 << 40
        var low = 0, high = Int.max // low ≤ H ≤ high
        var probe = max(0, (surfaceView.scrollbar.map { $0.total - $0.length } ?? 0) - rows / 2)
        var step = rows
        for _ in 0..<128 {
            scrollViewport(toRow: probe)
            switch activeAreaRow(surface, cols: cols) {
            case let row? where row > 0: return probe + row
            case 0?: high = min(high, probe)
            default: low = max(low, probe + rows)
            }
            guard low < high else { return low == high ? low : nil }
            if high == .max {
                guard low < maxProbe else { return nil }
                probe = low + step
                step = min(step * 2, maxProbe)
            } else {
                // Within a screen the next probe lands below H, so it answers exactly.
                probe = high - low < rows ? max(0, high - (rows - 1)) : low + (high - low) / 2
            }
        }
        return nil
    }

    /// `scroll_to_row` moves the viewport synchronously (the other scroll actions go through the IO thread); a row in
    /// the active area or below it pins the viewport to the active area, which then follows the output again.
    private func scrollViewport(toRow row: Int) {
        surfaceView.performBinding("scroll_to_row:\(max(0, row))")
    }

    /// Puts the viewport back after `historyRows`: following the output (`lead` 0), else at `top`. Without `top`,
    /// `lead` rows up from the bottom, which libghostty applies on its IO thread a moment later.
    private func restoreViewport(lead: Int, top: Int?) {
        if lead > 0, let top { return scrollViewport(toRow: top) }
        scrollViewport(toRow: .max)
        if lead > 0 { surfaceView.performBinding("scroll_page_lines:-\(lead)") }
    }

    /// Reads a selection's text plus where its top-left cell is in the viewport: position in points, (-1, -1) when
    /// the selection is not in the viewport, and `cell` = viewport row · columns + column (0 when outside).
    /// The returned text buffer is freed here.
    private func read(_ surface: ghostty_surface_t, _ sel: ghostty_selection_s) -> (text: String, x: Double, y: Double, cell: Int)? {
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, sel, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return (Self.string(from: text), text.tl_px_x, text.tl_px_y, Int(text.offset_start))
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
    func scrollbackText(maxLines: Int) -> String { textView.string }
    func historyRows(maxRows: Int) -> [String] { [] } // `visibleText()` already has all of it
    var cursorPosition: (row: Int, col: Int)? { nil }
    var gridSize: (rows: Int, cols: Int)? { nil }
    var foregroundProcessGroupID: pid_t? { nil }
    func close() { delegate?.terminalSurfaceDidClose(self) }
}
