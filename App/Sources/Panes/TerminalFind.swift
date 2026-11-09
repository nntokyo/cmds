import AppKit
import CmdsCore

/// ⌘F in a terminal pane (#173): the find bar and the search behind it.
///
/// - Default (plain text, case-insensitive): libghostty's own search (`TerminalSurface.search`), which runs on its own
///   thread, highlights every hit in the scrollback and on the screen, selects one, scrolls to it and reports counts.
/// - Match Case or Regular Expression: libghostty cannot, so the rows are read in slices on the main thread (never a
///   long stall), matched off it (`TerminalTextSearch`), and the selected hit is scrolled to and outlined
///   (`TerminalFindMarker`). A hit that wraps onto the next row is not found then.
///
/// Both start at the bottom; next (Return, ⌘G) goes up towards older output. While the bar is open the terminal never
/// takes the keyboard (`TerminalSurface.keyboardRedirect`). Esc closes it.
@MainActor
final class TerminalFind {
    private unowned let pane: Pane
    private(set) var bar: TerminalFindBar?
    private var marker: TerminalFindMarker?
    private var markerTimer: Timer?

    /// libghostty's figures (plain mode).
    private var engineTotal: Int?
    private var engineSelected: Int?
    /// The bar's own search (Match Case / Regular Expression).
    private var hits: [TerminalSearchMatch] = []
    private var hitIndex: Int?
    private var invalidPattern = false
    /// Reading rows or matching (own search); cancelled by the next change.
    private var searchTask: Task<Void, Never>?
    private var debounce: DispatchWorkItem?
    /// The engine search is running (plain mode with text).
    private var engineSearching = false

    /// Rows read per slice, then the main thread is let go for `slicePause` nanoseconds.
    private static let rowsPerSlice = 1500
    private static let slicePause: UInt64 = 1_000_000
    /// Seconds to wait after a change before searching: longer for needles shorter than `shortNeedle` characters,
    /// which match a lot (as Ghostty does).
    private static let shortNeedle = 3
    private static let shortNeedleDelay = 0.3
    private static let delay = 0.05
    /// How often the outline follows the selected hit (output and the user's scrolling move it).
    private static let markerRefreshInterval: TimeInterval = 0.25
    /// The own search reads at most this many rows from the bottom.
    static let maxRows = 200_000

    init(pane: Pane) {
        self.pane = pane
    }

    var isOpen: Bool { bar != nil }
    var text: String { bar?.field.stringValue ?? "" }
    var options: TerminalSearchOptions {
        TerminalSearchOptions(caseSensitive: bar?.matchCase ?? false, regex: bar?.regex ?? false)
    }

    // MARK: Open / close

    /// Shows the bar (or focuses it again) with `needle` if given, its text selected.
    func open(needle: String? = nil) {
        guard let terminal = pane.terminal else { return NSSound.beep() }
        if bar == nil {
            let bar = TerminalFindBar()
            bar.onChange = { [weak self] in self?.textOrOptionsChanged() }
            bar.onNavigate = { [weak self] next in self?.navigate(next: next) }
            bar.onClose = { [weak self] in self?.close() }
            bar.onFocus = { [weak self] in
                guard let self else { return }
                self.pane.controller?.paneDidBecomeFocused(self.pane)
            }
            self.bar = bar
            pane.container.setFindBar(bar)
        }
        guard let bar else { return }
        terminal.keyboardRedirect = bar.field
        if let needle, needle != bar.field.stringValue {
            bar.field.stringValue = needle
            textOrOptionsChanged()
        }
        bar.window?.makeFirstResponder(bar.field)
        bar.field.currentEditor()?.selectAll(nil)
        updateCount()
    }

    /// Hides the bar, ends the search and gives the keyboard back to the terminal.
    func close(refocus: Bool = true) {
        guard let bar else { return }
        stopSearching()
        self.bar = nil
        let hadKeyboard = bar.fieldHasKeyboard
        pane.container.setFindBar(nil)
        pane.terminal?.keyboardRedirect = nil
        if refocus, hadKeyboard { pane.terminal?.focus() }
    }

    /// The pane got a new terminal (SSH reconnect) or is going away.
    func reset() {
        close(refocus: false)
    }

    // MARK: Searching

    private func textOrOptionsChanged() {
        debounce?.cancel()
        let delay = text.count < Self.shortNeedle && !text.isEmpty ? Self.shortNeedleDelay : Self.delay
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.runSearch() }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Runs the current text and options now (also what `debug.find` uses after setting them).
    func runSearch() {
        cancelDebounce()
        guard let terminal = pane.terminal, isOpen else { return }
        let needle = text, options = options
        cancelOwnSearch()
        if !needle.isEmpty, options.isPlain {
            engineTotal = nil
            engineSelected = nil
            engineSearching = true
            terminal.search(needle)
        } else {
            endEngineSearch()
            if !needle.isEmpty {
                searchTask = Task { [weak self] in await self?.searchRows(needle, options: options) }
            }
        }
        updateCount()
    }

    /// The own search: reads the rows in slices, matches them off the main thread, selects the hit nearest the bottom
    /// of the viewport going up.
    private func searchRows(_ needle: String, options: TerminalSearchOptions) async {
        guard let terminal = pane.terminal, let total = terminal.scrollbar()?.total else { return }
        let first = max(0, total - Self.maxRows)
        var rows: [String] = []
        rows.reserveCapacity(total - first)
        var row = first
        while row < total {
            let end = min(row + Self.rowsPerSlice, total)
            guard !Task.isCancelled, let slice = pane.terminal?.screenRows(row..<end) else { return }
            rows.append(contentsOf: slice)
            row = end
            // Let events and drawing through between slices.
            try? await Task.sleep(nanoseconds: Self.slicePause)
        }
        // Rows pruned past the scrollback limit while reading shift the rest; the next change searches again.
        let found: Result<[TerminalSearchMatch], Error> = await Task.detached(priority: .userInitiated) {
            Result { try TerminalTextSearch.matches(needle, in: rows, firstRow: first, options: options) }
        }.value
        guard !Task.isCancelled, isOpen else { return }
        switch found {
        case .success(let matches):
            hits = matches
            invalidPattern = false
            let viewportBottom = terminal.scrollbar().map { $0.viewport.upperBound - 1 }
            hitIndex = TerminalTextSearch.nearestIndex(in: hits, atOrAbove: viewportBottom)
            showSelectedHit()
        case .failure:
            hits = []
            hitIndex = nil
            invalidPattern = true
        }
        searchTask = nil
        updateCount()
    }

    /// Next (`true`: up, older) or previous hit.
    func navigate(next: Bool) {
        guard isOpen else { return }
        if debounce != nil { runSearch() }
        if engineSearching {
            pane.terminal?.navigateSearch(next: next)
            return
        }
        guard !hits.isEmpty, let index = hitIndex else { return NSSound.beep() }
        hitIndex = next ? (index - 1 + hits.count) % hits.count : (index + 1) % hits.count
        showSelectedHit()
        updateCount()
    }

    /// Scrolls the selected hit to a third of the way down the viewport and outlines it.
    private func showSelectedHit() {
        guard let terminal = pane.terminal, let hit = selectedHit else { return }
        if let bar = terminal.scrollbar(), !bar.viewport.contains(hit.row) {
            terminal.scroll(toRow: hit.row - bar.rows / 3)
        }
        updateMarker()
        if markerTimer == nil {
            markerTimer = Timer.scheduledTimer(withTimeInterval: Self.markerRefreshInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMarker() }
            }
        }
    }

    private func updateMarker() {
        guard let terminal = pane.terminal, let hit = selectedHit, let bar = terminal.scrollbar(), bar.viewport.contains(hit.row),
              let rect = terminal.cellRect(viewportRow: hit.row - bar.offset, column: hit.column, width: hit.width) else {
            marker?.isHidden = true
            return
        }
        let marker = self.marker ?? TerminalFindMarker(frame: .zero)
        if self.marker == nil {
            self.marker = marker
            pane.container.setFindMarker(marker)
        }
        marker.frame = pane.container.convert(rect.insetBy(dx: -1, dy: -1), from: terminal.view)
        marker.isHidden = false
    }

    private var selectedHit: TerminalSearchMatch? { hitIndex.flatMap { hits[safe: $0] } }

    /// Reading or matching rows, or a change not searched yet (the count shows `…`).
    private var ownSearchPending: Bool { searchTask != nil || debounce != nil }

    private func cancelDebounce() {
        debounce?.cancel()
        debounce = nil
    }

    /// Stops reading / matching and drops the own search's hits and outline.
    private func cancelOwnSearch() {
        searchTask?.cancel()
        searchTask = nil
        hits = []
        hitIndex = nil
        invalidPattern = false
        markerTimer?.invalidate()
        markerTimer = nil
        marker = nil
        pane.container.setFindMarker(nil)
    }

    /// Ends libghostty's search (and its highlights) if it runs.
    private func endEngineSearch() {
        if engineSearching { pane.terminal?.endSearch() }
        engineSearching = false
        engineTotal = nil
        engineSelected = nil
    }

    private func stopSearching() {
        cancelDebounce()
        cancelOwnSearch()
        endEngineSearch()
    }

    // MARK: Engine events

    func engineDidUpdate(total: Int?, selected: Int?) {
        guard engineSearching else { return }
        engineTotal = total
        engineSelected = selected
        updateCount()
    }

    // MARK: Count

    /// `3/12` (the selected hit, counted from the bottom), `-/12` before one is selected, `0` without hits, `…` while
    /// reading.
    var countText: String {
        if text.isEmpty { return "" }
        if invalidPattern { return String(localized: "Invalid") }
        if engineSearching {
            guard let total = engineTotal else { return "…" }
            if let selected = engineSelected { return "\(selected + 1)/\(total)" }
            return total == 0 ? "0" : "-/\(total)"
        }
        if ownSearchPending { return "…" }
        guard let index = hitIndex else { return "0" }
        return "\(hits.count - index)/\(hits.count)"
    }

    private func updateCount() {
        bar?.countLabel.stringValue = countText
        bar?.setInvalid(invalidPattern)
    }

    #if DEBUG
    var debugContainer: NSView { pane.container }

    /// For `debug.find`: nothing pending (debounce, reading, matching, libghostty's first count).
    var debugSettled: Bool {
        debounce == nil && searchTask == nil && (!engineSearching || engineTotal != nil)
    }

    /// For `debug.find`: the state as the bar shows it, and the selected hit of the own search.
    var debugState: [String: JSONValue] {
        var state: [String: JSONValue] = [
            "open": .bool(isOpen), "text": .string(text), "count": .string(countText),
            "caseSensitive": .bool(options.caseSensitive), "regex": .bool(options.regex),
            "engine": .bool(engineSearching), "searching": .bool(ownSearchPending),
            "hits": .number(Double(engineSearching ? (engineTotal ?? -1) : hits.count)),
            "terminalHasKeyboard": .bool(pane.terminal.map { $0.view.window?.firstResponder === $0.view } ?? false),
        ]
        if let bar, bar.window != nil {
            state["fieldHasKeyboard"] = .bool(bar.fieldHasKeyboard)
        }
        if let hit = selectedHit {
            state["hit"] = ["row": .number(Double(hit.row)), "column": .number(Double(hit.column)),
                            "width": .number(Double(hit.width))]
            state["markerVisible"] = .bool(marker?.isHidden == false)
            if let marker {
                let f = marker.frame
                state["markerFrame"] = [.number(f.minX), .number(f.minY), .number(f.width), .number(f.height)]
            }
        }
        if let bar = pane.terminal?.scrollbar() {
            state["scrollbar"] = ["total": .number(Double(bar.total)), "offset": .number(Double(bar.offset)),
                                  "rows": .number(Double(bar.rows))]
        }
        return state
    }

    /// For `debug.find`: sets the options as the toggles would.
    func debugSetOptions(caseSensitive: Bool?, regex: Bool?) {
        if let caseSensitive { bar?.caseButton.state = caseSensitive ? .on : .off }
        if let regex { bar?.regexButton.state = regex ? .on : .off }
    }

    func debugSetText(_ text: String) {
        bar?.field.stringValue = text
    }
    #endif
}

private extension TerminalScrollbar {
    /// Screen rows in the viewport.
    var viewport: Range<Int> { offset..<(offset + rows) }
}
