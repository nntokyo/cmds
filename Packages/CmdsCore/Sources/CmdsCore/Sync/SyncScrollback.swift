import Foundation

/// Rows above the screen (`requestScrollback` / `scrollback`, docs/internals/sync-protocol.md "Scrollback").
public enum SyncScrollback {
    /// Most rows the Mac sends for one request.
    public static let maxLines = 1000

    /// Rows sent for a request of `lines`: at least 1, at most `maxLines`.
    public static func clampedLines(_ lines: Int) -> Int {
        min(max(lines, 1), maxLines)
    }
}

// MARK: - Mac side

/// A terminal's viewport in its whole screen, in rows: the history (scrollback) on top of the active area
/// (`TerminalSurface.scrollbar()` in the Mac app).
public struct TerminalScrollbar: Equatable, Sendable {
    /// Rows of the whole screen.
    public var total: Int
    /// Screen row at the top of the viewport, i.e. the number of rows above it: `total − rows` while the viewport
    /// follows the output, less while it is scrolled up; 0 on the alternate screen, which has no history.
    public var offset: Int
    /// Rows of the viewport.
    public var rows: Int
    /// Rows pruned from the top of the history past the scrollback limit so far (since the screen was created):
    /// screen rows read earlier moved up by the difference. Clearing the history or resizing does not count.
    public var pruned: Int

    public init(total: Int, offset: Int, rows: Int, pruned: Int) {
        self.total = total
        self.offset = offset
        self.rows = rows
        self.pruned = pruned
    }
}

/// What a screen update carries for a streaming phone's rows above the screen (`SyncFeature.scrollbackStream`).
public enum HistoryUpdate: Equatable, Sendable {
    case unchanged
    /// Rows that left the top of the screen since the previous update, oldest first (`scrolledOff`).
    case scrolledOff([String])
    /// The rows above this screen do not continue the phone's (`historyReset`); it asks again.
    case reset
}

/// Where the rows a streaming phone has above a pane's screen end (`SyncFeature.scrollbackStream`): the viewport
/// of the last screen it got with rows above it, and the last few of those rows. Rows above the active area are
/// history, which programs cannot change: pruning past the scrollback limit moves them up by the rows pruned
/// (`TerminalScrollbar.pruned`), and clearing the history removes them.
public struct HistoryMark: Equatable, Sendable {
    /// The last rows a streaming phone has above a pane's screen, read again with every update as a safety net.
    public static let checkRows = 4

    public private(set) var bar: TerminalScrollbar
    public private(set) var cols: Int
    /// At most `checkRows`, oldest first; the last one is screen row `bar.offset − 1`.
    public private(set) var tail: [String]

    /// The mark for a screen read with `bar` (`cols` wide) and the phone's rows above it, oldest first (only the last
    /// `checkRows` are kept).
    public init(bar: TerminalScrollbar, cols: Int, rows: [String]) {
        self.bar = bar
        self.cols = cols
        tail = Array(rows.suffix(Self.checkRows))
    }

    /// `bar` as screen rows of `now`: rows pruned since moved every row up by as many. nil when fewer rows count
    /// as pruned than then (another screen: alternate, or recreated).
    public func moved(to now: TerminalScrollbar) -> TerminalScrollbar? {
        let shift = now.pruned - bar.pruned
        guard shift >= 0 else { return nil }
        return TerminalScrollbar(total: bar.total - shift, offset: bar.offset - shift, rows: bar.rows,
                                 pruned: now.pruned)
    }

    /// The phone's rows no longer end right above a viewport at `now` (rows left the screen, the history changed under
    /// them, another screen): it needs an update even when the screen's text did not change.
    public func isBehind(_ now: TerminalScrollbar) -> Bool {
        guard let base = moved(to: now) else { return true }
        return now.offset != base.offset || now.total < base.total
    }

    /// The update for a screen of `rows` × `cols` read with the viewport at `bar` (nil when it moved meanwhile):
    /// `.scrolledOff` with the rows that left the top of the screen since the mark, which then moves to `bar`;
    /// `.reset` when the rows above the screen no longer continue the phone's (drop the mark); `.unchanged` while
    /// `bar` is unknown or the rows cannot be read (a later update catches up; the mark stays), or when no rows left.
    /// `readRows(n)`: the `n` rows right above the viewport at `bar`, oldest first, as sent, or nil when they cannot be
    /// read at `bar`.
    public mutating func update(rows: Int, cols: Int, bar: TerminalScrollbar?,
                                readRows: (Int) -> [String]?) -> HistoryUpdate {
        // Resized: the rows above the screen were rewrapped, or moved into it.
        guard rows == self.bar.rows, cols == self.cols else { return .reset }
        guard let bar else { return .unchanged }
        // The mark in today's screen rows: rows pruned past the scrollback limit since then moved it up. Another
        // screen (alternate), or the phone's last rows pruned too: nothing continues them.
        guard let base = moved(to: bar), base.offset - tail.count >= 0 else { return .reset }
        // History cleared, alternate screen, scrolled up on the Mac, or more rows at once than an answer has.
        guard bar.rows == base.rows, bar.total >= base.total, bar.offset >= base.offset,
              bar.offset - base.offset <= SyncScrollback.maxLines else { return .reset }
        // Screen rows base.offset − tail ..< bar.offset.
        let count = bar.offset - base.offset + tail.count
        var scrolledOff: [String] = []
        if count > 0 {
            guard let read = readRows(count), read.count == count else { return .unchanged }
            // The phone's last rows read differently: the history changed under them although nothing counts as
            // cleared or pruned (a safety net).
            guard read.prefix(tail.count).elementsEqual(tail) else { return .reset }
            scrolledOff = Array(read.dropFirst(tail.count))
        }
        self = HistoryMark(bar: bar, cols: cols, rows: tail + scrolledOff)
        return scrolledOff.isEmpty ? .unchanged : .scrolledOff(scrolledOff)
    }
}

// MARK: - Phone side

/// The rows above a pane's screen as the phone has them (`HistoryMirror`).
public struct PaneHistory: Equatable, Sendable {
    /// Oldest first; the last one is directly above the screen's first row.
    public var lines: [String]
    /// Rows dropped from the top since these rows began: `lines[i]` is row `first + i`. A row keeps its number (its
    /// identity in the view) while rows are added at the bottom and dropped at the top.
    public var first: Int
    /// `SyncFeature.styles`: the style runs of the rows that have any, by row number (`first + i`).
    public var runs: [Int: [StyleRun]]

    public init(lines: [String] = [], first: Int = 0, runs: [Int: [StyleRun]] = [:]) {
        self.lines = lines
        self.first = first
        self.runs = runs
    }

    /// `lines` with the runs of `styles` (`RowStyle.row` indexes `lines`), numbered from `first`.
    public init(lines: [String], styles: [RowStyle]?, first: Int = 0) {
        self.init(lines: lines, first: first)
        add(styles, from: first)
    }

    /// The runs of row number `row` (empty: plain).
    public func runs(row: Int) -> [StyleRun] { runs[row] ?? [] }

    /// Adds rows at the bottom and drops the oldest beyond `cap`. `styles` index `rows`.
    public mutating func append(_ rows: [String], styles: [RowStyle]? = nil, keepingAtMost cap: Int) {
        add(styles, from: first + lines.count, count: rows.count)
        lines.append(contentsOf: rows)
        dropOldest(lines.count - cap)
    }

    /// Drops the `count` oldest rows (nothing when `count` is not positive).
    public mutating func dropOldest(_ count: Int) {
        guard count > 0 else { return }
        let dropped = min(count, lines.count)
        lines.removeFirst(dropped)
        first += dropped
        if !runs.isEmpty { runs = runs.filter { $0.key >= first } }
    }

    private mutating func add(_ styles: [RowStyle]?, from number: Int, count: Int = .max) {
        for style in styles ?? [] where style.row >= 0 && style.row < count && !style.runs.isEmpty {
            runs[number + style.row] = style.runs
        }
    }
}

/// Phone side: the rows above each streamed pane's screen (`histories`), from `scrollback` answers and, from a Mac that
/// streams them (`SyncFeature.scrollbackStream`), the rows that scroll off with every screen update. While a pane's
/// earlier output is read (`setReading`), the shown rows only grow at the bottom: no rows are dropped below
/// `maxRowsWhileReading`, and rows that do not continue them wait until reading ends.
public struct HistoryMirror: Sendable {
    /// Rows kept above a screen, and while it is read: dropping rows at the top would move the text being read.
    public static let maxRows = 2000
    public static let maxRowsWhileReading = 10_000
    /// `rows(after:in:)`: the last shown rows looked for in an answer, how many of them it needs at least, and how many
    /// of those must not be blank, so that a match is not a coincidence.
    static let matchRows = 24
    static let minMatchRows = 8
    static let minNonBlankMatchRows = 3

    /// The rows shown above each pane's screen.
    public private(set) var histories: [String: PaneHistory] = [:]
    /// The connected Mac streams the rows that scroll off (`connected(streams:)`).
    public private(set) var streams = false
    /// Streaming Mac, pane being read: its rows once they no longer continue the shown ones (a reset or a new
    /// connection whose answer does not continue them, `maxRowsWhileReading` reached). The shown rows stay as they
    /// are, because any change above the rows being read would move them; these replace them when reading ends.
    private var pending: [String: PaneHistory] = [:]
    /// Panes whose earlier output the user is reading (`setReading`).
    private var reading: Set<String> = []
    /// Streaming Mac: panes whose `requestScrollback` it answered on this connection, so their screen updates carry
    /// the rows that scroll off (`scrolledOff`) or `historyReset`.
    private var streamed: Set<String> = []

    public init() {}

    /// The Mac streams this pane's rows: it needs no further `requestScrollback` until a `historyReset`.
    public func isStreamed(_ paneID: String) -> Bool { streamed.contains(paneID) }

    /// A new connection (`welcome`): possibly another Mac (pane ids are per Mac) or one without `scrollback`, so the
    /// rows are asked for again. With a streaming Mac, rows being read stay until reading ends.
    public mutating func connected(streams: Bool) {
        self.streams = streams
        streamed = []
        if streams {
            for paneID in Set(histories.keys).union(pending.keys) { replace(paneID, with: nil) }
        } else {
            histories = [:]
            pending = [:]
        }
    }

    /// A `scrollback` answer (it follows the full `screen` it was read with). From a streaming Mac it starts the
    /// stream of the pane, and when it still has the last shown rows only the newer rows are added.
    public mutating func receive(_ lines: [String], styles: [RowStyle]? = nil, paneID: String) {
        if streams {
            streamed.insert(paneID)
            if continueHistory(paneID, with: lines, styles: styles) { return }
        }
        replace(paneID, with: PaneHistory(lines: lines, styles: styles))
    }

    /// `scrolledOff` / `historyReset` of a screen update from a streaming Mac (for panes whose request it answered).
    /// True after a reset: ask again (`requestScrollback`).
    public mutating func extend(paneID: String, scrolledOff rows: [String]?, styles: [RowStyle]? = nil,
                                reset: Bool) -> Bool {
        guard streams, streamed.contains(paneID) else { return false }
        if reset {
            // The rows above the screen no longer continue these: ask again. The answer replaces them, or adds the
            // newer rows when it still has the last of them (`continueHistory`). Until then they stay: dropping them
            // at once would make the screen jump whenever rows above it are in view.
            streamed.remove(paneID)
            return true
        }
        if let rows { append(paneID, rows, styles: styles) }
        return false
    }

    /// The view of a pane stopped following its screen to read earlier output (`isReading`), or follows it again.
    /// When reading ends, the rows that waited are shown and the rows are trimmed to `maxRows`.
    public mutating func setReading(paneID: String, _ isReading: Bool) {
        if isReading {
            reading.insert(paneID)
        } else if reading.remove(paneID) != nil {
            showPending(paneID)
        }
    }

    /// Latest: the rows held back while reading (else the shown ones) are shown, trimmed to `maxRows`. The pane still
    /// counts as read until `setReading(paneID:false)`.
    public mutating func showPending(_ paneID: String) {
        guard var history = pending.removeValue(forKey: paneID) ?? histories[paneID] else { return }
        history.dropOldest(history.lines.count - Self.maxRows)
        if histories[paneID] != history { histories[paneID] = history }
    }

    /// Drops the rows (and the reading state) of panes that are no longer streamed or gone.
    public mutating func forget(where gone: (String) -> Bool) {
        for paneID in histories.keys where gone(paneID) { histories[paneID] = nil }
        pending = pending.filter { !gone($0.key) }
        streamed = streamed.filter { !gone($0) }
        reading = reading.filter { !gone($0) }
    }

    /// A pane's rows from a `scrollback` answer, or none (new connection). While a streaming Mac's pane is read, they
    /// wait in `pending` and the shown rows stay.
    private mutating func replace(_ paneID: String, with history: PaneHistory?) {
        if streams, reading.contains(paneID) {
            pending[paneID] = history ?? PaneHistory()
            return
        }
        pending[paneID] = nil
        if histories[paneID] != history { histories[paneID] = history }
    }

    /// A streaming Mac's answer that still has the last shown rows (after a reset that left them in place, or a new
    /// connection): adds the newer rows below them, so rows being read stay where they are and keep growing. False
    /// when it does not continue them, or reaches further back while the pane is not read.
    private mutating func continueHistory(_ paneID: String, with answer: [String], styles: [RowStyle]?) -> Bool {
        guard let shown = histories[paneID]?.lines, let newer = Self.rows(after: shown, in: answer) else { return false }
        if !reading.contains(paneID), answer.count > shown.count + newer.count { return false }
        pending[paneID] = nil
        append(paneID, Array(newer), styles: RowStyle.slice(styles, newer.startIndex..<newer.endIndex))
        return true
    }

    /// Adds rows below a pane's rows, or below the pending ones while there are. Rows being read are never dropped at
    /// the top: once they are full they stay, and the rest waits in `pending`.
    private mutating func append(_ paneID: String, _ rows: [String], styles: [RowStyle]?) {
        guard !rows.isEmpty else { return }
        let isReading = reading.contains(paneID)
        let cap = isReading ? Self.maxRowsWhileReading : Self.maxRows
        if pending[paneID] != nil {
            pending[paneID]?.append(rows, styles: styles, keepingAtMost: cap)
        } else if isReading, (histories[paneID]?.lines.count ?? 0) + rows.count > cap {
            var waiting = histories[paneID] ?? PaneHistory()
            waiting.append(rows, styles: styles, keepingAtMost: cap)
            pending[paneID] = waiting
        } else {
            histories[paneID, default: PaneHistory()].append(rows, styles: styles, keepingAtMost: cap)
        }
    }

    /// The rows of `answer` after the last of `shown`, when `answer` has those last rows (the latest place, so repeated
    /// text adds as few rows as possible). Needs enough of them, some not blank, so the match is not a coincidence.
    static func rows(after shown: [String], in answer: [String]) -> ArraySlice<String>? {
        let tail = shown.suffix(matchRows)
        guard tail.count >= minMatchRows, tail.filter({ !$0.isEmpty }).count >= minNonBlankMatchRows else { return nil }
        var end = answer.count
        while end >= tail.count {
            if answer[(end - tail.count)..<end].elementsEqual(tail) { return answer[end...] }
            end -= 1
        }
        return nil
    }
}
