/// The rows above a pane's screen as the phone has them (`CompanionClient.histories`).
struct PaneHistory: Equatable {
    /// Oldest first; the last one is directly above the screen's first row.
    var lines: [String] = []
    /// Rows dropped from the top since these rows began: `lines[i]` is row `first + i`. A row keeps its number (its
    /// identity in the view) while rows are added at the bottom and dropped at the top.
    var first = 0

    /// Adds rows at the bottom and drops the oldest beyond `cap`.
    mutating func append(_ rows: [String], keepingAtMost cap: Int) {
        lines.append(contentsOf: rows)
        dropOldest(lines.count - cap)
    }

    /// Drops the `count` oldest rows (nothing when `count` is not positive).
    mutating func dropOldest(_ count: Int) {
        guard count > 0 else { return }
        let dropped = min(count, lines.count)
        lines.removeFirst(dropped)
        first += dropped
    }
}
