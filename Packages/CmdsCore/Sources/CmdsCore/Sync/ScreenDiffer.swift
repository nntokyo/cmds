import Foundation

/// Row-level diff of terminal screens (pure functions).
public enum ScreenDiffer {
    public enum ApplyError: Error, Equatable {
        case rowOutOfRange(Int)
    }

    /// Rows of `new` that differ from `old`. Returns nil when the row counts differ
    /// (a full screen must be sent instead).
    public static func diff(from old: [String], to new: [String]) -> [LineChange]? {
        guard old.count == new.count else { return nil }
        var changes: [LineChange] = []
        for row in new.indices where old[row] != new[row] {
            changes.append(LineChange(row: row, text: new[row]))
        }
        return changes
    }

    /// `lines` with `changes` applied.
    public static func apply(_ changes: [LineChange], to lines: [String]) throws -> [String] {
        var result = lines
        for change in changes {
            guard result.indices.contains(change.row) else { throw ApplyError.rowOutOfRange(change.row) }
            result[change.row] = change.text
        }
        return result
    }

    /// Approximate encoded size, used to decide whether a diff is worth sending.
    static func payloadCost(_ lines: [String]) -> Int {
        lines.reduce(0) { $0 + $1.utf8.count + 3 }
    }

    static func payloadCost(_ changes: [LineChange]) -> Int {
        changes.reduce(0) { $0 + $1.text.utf8.count + 20 }
    }
}

/// Mac side, one per connected phone: turns successive pane snapshots into `screen` /
/// `screenDiff` messages and tracks per-pane `seq`.
///
///     var streamer = ScreenStreamer()
///     // on subscribe:          streamer.reset(paneID:) then send streamer.update(...)
///     // on every screen tick:  if let msg = streamer.update(paneID:, snapshot:) { send(msg) }
///     // on requestScreen:      send(streamer.fullScreen(paneID:))
public struct ScreenStreamer: Sendable {
    private struct PaneState: Sendable {
        var seq: UInt64
        var last: ScreenSnapshot?
    }

    private var panes: [String: PaneState] = [:]
    /// Send a full screen instead of a diff when the diff is larger than this fraction of it.
    public var maxDiffRatio: Double

    public init(maxDiffRatio: Double = 0.6) {
        self.maxDiffRatio = maxDiffRatio
    }

    /// Message to send for `snapshot`, or nil when nothing changed since the last one sent.
    public mutating func update(paneID: String, snapshot: ScreenSnapshot) -> ServerMessage? {
        var state = panes[paneID] ?? PaneState(seq: 0, last: nil)
        defer { panes[paneID] = state }

        guard let last = state.last else {
            state.seq += 1
            state.last = snapshot
            return .screen(.init(paneID: paneID, seq: state.seq, snapshot: snapshot))
        }
        if last == snapshot { return nil }

        let baseSeq = state.seq
        state.seq += 1
        state.last = snapshot
        if last.rows == snapshot.rows, last.cols == snapshot.cols,
           let changes = ScreenDiffer.diff(from: last.lines, to: snapshot.lines),
           Double(ScreenDiffer.payloadCost(changes)) <= Double(ScreenDiffer.payloadCost(snapshot.lines)) * maxDiffRatio {
            return .screenDiff(.init(paneID: paneID, seq: state.seq, baseSeq: baseSeq, changes: changes,
                                     cursorRow: snapshot.cursorRow, cursorCol: snapshot.cursorCol))
        }
        return .screen(.init(paneID: paneID, seq: state.seq, snapshot: snapshot))
    }

    /// Full `screen` of the last snapshot (for `requestScreen`); nil if none seen yet.
    /// Bumps `seq` so later diffs are based on this message.
    public mutating func fullScreen(paneID: String) -> ServerMessage? {
        guard var state = panes[paneID], let last = state.last else { return nil }
        state.seq += 1
        panes[paneID] = state
        return .screen(.init(paneID: paneID, seq: state.seq, snapshot: last))
    }

    /// Forget what was sent for a pane so the next `update` produces a full screen.
    /// `seq` keeps increasing so the phone never sees it go backwards.
    public mutating func reset(paneID: String) {
        panes[paneID]?.last = nil
    }

    /// Drop all state for panes not in `paneIDs` (unsubscribed or closed).
    public mutating func retain(paneIDs: Set<String>) {
        panes = panes.filter { paneIDs.contains($0.key) }
    }
}

/// Phone side: applies `screen` / `screenDiff` messages to keep a copy of each pane.
public struct ScreenMirror: Sendable {
    public struct PaneScreen: Equatable, Sendable {
        public var seq: UInt64
        public var snapshot: ScreenSnapshot
    }

    public enum ApplyResult: Equatable, Sendable {
        /// Screen updated.
        case updated(paneID: String)
        /// Message was older than what we have; ignored.
        case stale
        /// Diff did not match our base; send `requestScreen(paneID)`.
        case needsFullScreen(paneID: String)
    }

    public private(set) var panes: [String: PaneScreen] = [:]

    public init() {}

    public subscript(paneID: String) -> ScreenSnapshot? { panes[paneID]?.snapshot }

    public mutating func apply(_ screen: ServerMessage.Screen) -> ApplyResult {
        if let current = panes[screen.paneID], current.seq >= screen.seq { return .stale }
        panes[screen.paneID] = PaneScreen(seq: screen.seq, snapshot: screen.snapshot)
        return .updated(paneID: screen.paneID)
    }

    public mutating func apply(_ diff: ServerMessage.ScreenDiff) -> ApplyResult {
        guard var current = panes[diff.paneID] else { return .needsFullScreen(paneID: diff.paneID) }
        if current.seq >= diff.seq { return .stale }
        guard current.seq == diff.baseSeq,
              let lines = try? ScreenDiffer.apply(diff.changes, to: current.snapshot.lines)
        else { return .needsFullScreen(paneID: diff.paneID) }
        current.seq = diff.seq
        current.snapshot.lines = lines
        current.snapshot.cursorRow = diff.cursorRow
        current.snapshot.cursorCol = diff.cursorCol
        panes[diff.paneID] = current
        return .updated(paneID: diff.paneID)
    }

    public mutating func remove(paneID: String) { panes[paneID] = nil }
    public mutating func removeAll() { panes.removeAll() }
}
