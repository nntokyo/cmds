import XCTest
@testable import CmdsCore

/// The Mac's mark of where a streaming phone's rows above a screen end (`HistoryMark`, `SyncFeature.scrollbackStream`).
/// A fake history of numbered rows: screen row `n` reads "`n`" (shifted by the rows pruned).
final class SyncHistoryMarkTests: XCTestCase {
    /// 100 rows above a 24-row viewport, nothing pruned yet.
    private let start = TerminalScrollbar(total: 124, offset: 100, rows: 24, pruned: 0)

    /// The rows right above the viewport at `bar`, as numbers of the original output (pruned rows counted in).
    private func rows(above bar: TerminalScrollbar, _ count: Int) -> [String] {
        (bar.offset - count ..< bar.offset).map { String($0 + bar.pruned) }
    }

    private func mark(at bar: TerminalScrollbar) -> HistoryMark {
        HistoryMark(bar: bar, cols: 80, rows: rows(above: bar, 500))
    }

    func testKeepsTheLastRowsOfAnAnswer() {
        XCTAssertEqual(mark(at: start).tail, ["96", "97", "98", "99"])
        XCTAssertEqual(HistoryMark(bar: start, cols: 80, rows: ["a"]).tail, ["a"])
        XCTAssertEqual(HistoryMark(bar: start, cols: 80, rows: []).tail, [])
        XCTAssertEqual(HistoryMark.checkRows, 4)
    }

    func testMovedByThePrunedRows() {
        let mark = mark(at: start)
        XCTAssertEqual(mark.moved(to: start), start)
        let pruned = TerminalScrollbar(total: 130, offset: 106, rows: 24, pruned: 30)
        XCTAssertEqual(mark.moved(to: pruned), TerminalScrollbar(total: 94, offset: 70, rows: 24, pruned: 30))
        // Fewer rows counted as pruned: another screen.
        let other = mark.moved(to: pruned).map { HistoryMark(bar: $0, cols: 80, rows: []) }
        XCTAssertNil(other?.moved(to: start))
    }

    func testIsBehind() {
        let mark = mark(at: start)
        XCTAssertFalse(mark.isBehind(start))
        // Rows scrolled off.
        XCTAssertTrue(mark.isBehind(TerminalScrollbar(total: 130, offset: 106, rows: 24, pruned: 0)))
        // As many rows pruned as scrolled off: the same figures, but the rows moved.
        XCTAssertTrue(mark.isBehind(TerminalScrollbar(total: 124, offset: 100, rows: 24, pruned: 6)))
        // Rows pruned only (offset and total follow): still where the phone's rows end.
        XCTAssertFalse(mark.isBehind(TerminalScrollbar(total: 118, offset: 94, rows: 24, pruned: 6)))
        // History cleared; scrolled up on the Mac; another screen.
        XCTAssertTrue(mark.isBehind(TerminalScrollbar(total: 24, offset: 0, rows: 24, pruned: 0)))
        XCTAssertTrue(mark.isBehind(TerminalScrollbar(total: 124, offset: 90, rows: 24, pruned: 0)))
        XCTAssertTrue(mark.isBehind(TerminalScrollbar(total: 124, offset: 100, rows: 24, pruned: -1)))
    }

    func testRowsThatScrolledOffContinueTheTail() {
        var mark = mark(at: start)
        let now = TerminalScrollbar(total: 130, offset: 106, rows: 24, pruned: 0)
        var asked: [Int] = []
        let update = mark.update(rows: 24, cols: 80, bar: now) { count in
            asked.append(count)
            return self.rows(above: now, count)
        }
        // The tail is read again with the new rows.
        XCTAssertEqual(asked, [10])
        XCTAssertEqual(update, .scrolledOff(["100", "101", "102", "103", "104", "105"]))
        XCTAssertEqual(mark, HistoryMark(bar: now, cols: 80, rows: ["102", "103", "104", "105"]))
    }

    func testFollowsPruning() {
        var mark = mark(at: start)
        // 40 rows printed, 30 of them pruned at the top meanwhile.
        let now = TerminalScrollbar(total: 134, offset: 110, rows: 24, pruned: 30)
        let update = mark.update(rows: 24, cols: 80, bar: now) { self.rows(above: now, $0) }
        XCTAssertEqual(update, .scrolledOff((100..<140).map(String.init)))
        XCTAssertEqual(mark.bar, now)
        XCTAssertEqual(mark.tail, ["136", "137", "138", "139"])
    }

    func testNothingNewMovesTheMarkOnly() {
        var mark = mark(at: start)
        let now = TerminalScrollbar(total: 118, offset: 94, rows: 24, pruned: 6)
        XCTAssertEqual(mark.update(rows: 24, cols: 80, bar: now) { self.rows(above: now, $0) }, .unchanged)
        XCTAssertEqual(mark, HistoryMark(bar: now, cols: 80, rows: ["96", "97", "98", "99"]))

        // No tail (no rows above when answered) and nothing scrolled off: nothing is read.
        let empty = TerminalScrollbar(total: 24, offset: 0, rows: 24, pruned: 0)
        var bare = HistoryMark(bar: empty, cols: 80, rows: [])
        XCTAssertEqual(bare.update(rows: 24, cols: 80, bar: empty) { _ in XCTFail("read"); return nil }, .unchanged)
        XCTAssertEqual(bare, HistoryMark(bar: empty, cols: 80, rows: []))
    }

    func testWaitsWhileTheViewportIsUnknownOrTheRowsCannotBeRead() {
        let mark = mark(at: start)
        var copy = mark
        XCTAssertEqual(copy.update(rows: 24, cols: 80, bar: nil) { _ in XCTFail("read"); return nil }, .unchanged)
        XCTAssertEqual(copy, mark)
        let now = TerminalScrollbar(total: 130, offset: 106, rows: 24, pruned: 0)
        XCTAssertEqual(copy.update(rows: 24, cols: 80, bar: now) { _ in nil }, .unchanged)
        XCTAssertEqual(copy, mark)
        // Fewer rows than asked for.
        XCTAssertEqual(copy.update(rows: 24, cols: 80, bar: now) { _ in ["99"] }, .unchanged)
        XCTAssertEqual(copy, mark)
    }

    func testResets() {
        let mark = mark(at: start)
        func update(rows: Int = 24, cols: Int = 80, _ bar: TerminalScrollbar?,
                    read: (Int) -> [String]? = { _ in XCTFail("read"); return nil }) -> HistoryUpdate {
            var copy = mark
            return copy.update(rows: rows, cols: cols, bar: bar, readRows: read)
        }
        // Resized (also while the viewport is unknown).
        XCTAssertEqual(update(rows: 30, nil), .reset)
        XCTAssertEqual(update(cols: 100, start), .reset)
        // Another screen.
        XCTAssertEqual(update(TerminalScrollbar(total: 124, offset: 100, rows: 24, pruned: -1)), .reset)
        // The phone's last rows were pruned too.
        XCTAssertEqual(update(TerminalScrollbar(total: 124, offset: 100, rows: 24, pruned: 97)), .reset)
        // Viewport height differs from the mark's.
        XCTAssertEqual(update(TerminalScrollbar(total: 130, offset: 106, rows: 30, pruned: 0)), .reset)
        // History cleared.
        XCTAssertEqual(update(TerminalScrollbar(total: 24, offset: 0, rows: 24, pruned: 0)), .reset)
        // Scrolled up on the Mac.
        XCTAssertEqual(update(TerminalScrollbar(total: 124, offset: 90, rows: 24, pruned: 0)), .reset)
        // More rows at once than an answer has, and exactly that many.
        let burst = SyncScrollback.maxLines
        XCTAssertEqual(update(TerminalScrollbar(total: 124 + burst + 1, offset: 100 + burst + 1, rows: 24, pruned: 0)),
                       .reset)
        let most = TerminalScrollbar(total: 124 + burst, offset: 100 + burst, rows: 24, pruned: 0)
        guard case .scrolledOff(let rows) = update(most, read: { self.rows(above: most, $0) }) else {
            return XCTFail("\(burst) rows at once")
        }
        XCTAssertEqual(rows.count, burst)
        // The tail reads differently: the history changed under it.
        let now = TerminalScrollbar(total: 130, offset: 106, rows: 24, pruned: 0)
        XCTAssertEqual(update(now, read: { Array(repeating: "x", count: $0) }), .reset)
    }
}
