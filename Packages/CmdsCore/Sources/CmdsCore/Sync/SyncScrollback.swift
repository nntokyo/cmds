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
