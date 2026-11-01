import XCTest
@testable import CmdsCore

/// The phone's rows above each pane's screen (`PaneHistory`, `HistoryMirror`).
final class SyncHistoryMirrorTests: XCTestCase {
    /// "line 1" … "line n".
    private func lines(_ range: ClosedRange<Int>) -> [String] { range.map { "line \($0)" } }

    func testPaneHistoryNumbersRowsAcrossDrops() {
        var history = PaneHistory(lines: lines(1...3))
        history.append(lines(4...5), keepingAtMost: 4)
        XCTAssertEqual(history, PaneHistory(lines: lines(2...5), first: 1))
        history.dropOldest(0)
        history.dropOldest(-3)
        XCTAssertEqual(history.first, 1)
        history.dropOldest(10)
        XCTAssertEqual(history, PaneHistory(lines: [], first: 5))
    }

    func testRowsAfterTheLastShownRows() {
        let shown = lines(1...30)
        // The latest place of the last 24 rows.
        XCTAssertEqual(HistoryMirror.rows(after: shown, in: lines(1...40)).map(Array.init), lines(31...40))
        XCTAssertEqual(HistoryMirror.rows(after: shown, in: lines(7...30)).map(Array.init), [])
        // Only the last 24 shown rows count.
        XCTAssertEqual(HistoryMirror.rows(after: shown, in: lines(7...35)).map(Array.init), lines(31...35))
        XCTAssertNil(HistoryMirror.rows(after: shown, in: lines(8...35)))
        XCTAssertNil(HistoryMirror.rows(after: shown, in: lines(40...80)))
        // Repeated text: the latest match.
        let repeated = lines(1...10)
        XCTAssertEqual(HistoryMirror.rows(after: repeated, in: repeated + ["x"] + repeated + ["y"]).map(Array.init),
                       ["y"])
        // At least 8 rows, 3 of them not blank.
        XCTAssertNil(HistoryMirror.rows(after: lines(1...7), in: lines(1...9)))
        XCTAssertEqual(HistoryMirror.rows(after: lines(1...8), in: lines(1...9)).map(Array.init), ["line 9"])
        let blank = ["a", "b"] + Array(repeating: "", count: 8)
        XCTAssertNil(HistoryMirror.rows(after: blank, in: blank + ["c"]))
        XCTAssertNotNil(HistoryMirror.rows(after: ["c"] + blank, in: ["c"] + blank + ["d"]))
        XCTAssertEqual(HistoryMirror.matchRows, 24)
        XCTAssertEqual(HistoryMirror.minMatchRows, 8)
        XCTAssertEqual(HistoryMirror.minNonBlankMatchRows, 3)
    }

    /// A Mac without `scrollbackStream`: every answer replaces the rows, also while they are read; no rows are added.
    func testAnswersReplaceWithoutTheStream() {
        var mirror = HistoryMirror()
        mirror.connected(streams: false)
        mirror.receive(lines(1...30), paneID: "p")
        XCTAssertEqual(mirror.histories["p"], PaneHistory(lines: lines(1...30)))
        XCTAssertFalse(mirror.isStreamed("p"))
        mirror.setReading(paneID: "p", true)
        mirror.receive(lines(1...40), paneID: "p")
        XCTAssertEqual(mirror.histories["p"], PaneHistory(lines: lines(1...40)))
        XCTAssertFalse(mirror.extend(paneID: "p", scrolledOff: ["line 41"], reset: false))
        XCTAssertFalse(mirror.extend(paneID: "p", scrolledOff: nil, reset: true))
        XCTAssertEqual(mirror.histories["p"], PaneHistory(lines: lines(1...40)))
        // A new connection drops every pane's rows.
        mirror.connected(streams: false)
        XCTAssertEqual(mirror.histories, [:])
    }

    func testStreamAppendsUntilAReset() {
        var mirror = HistoryMirror()
        mirror.connected(streams: true)
        // Rows only after the answer.
        XCTAssertFalse(mirror.extend(paneID: "p", scrolledOff: ["x"], reset: false))
        XCTAssertNil(mirror.histories["p"])
        mirror.receive(lines(1...30), paneID: "p")
        XCTAssertTrue(mirror.isStreamed("p"))
        XCTAssertFalse(mirror.extend(paneID: "p", scrolledOff: lines(31...32), reset: false))
        XCTAssertFalse(mirror.extend(paneID: "p", scrolledOff: nil, reset: false))
        XCTAssertEqual(mirror.histories["p"], PaneHistory(lines: lines(1...32)))
        // A reset: ask again, the rows stay until the answer, no rows meanwhile.
        XCTAssertTrue(mirror.extend(paneID: "p", scrolledOff: nil, reset: true))
        XCTAssertFalse(mirror.isStreamed("p"))
        XCTAssertFalse(mirror.extend(paneID: "p", scrolledOff: ["line 33"], reset: false))
        XCTAssertEqual(mirror.histories["p"], PaneHistory(lines: lines(1...32)))
        // An answer that still has the last rows adds the newer ones below them (row numbers kept).
        mirror.receive(lines(5...40), paneID: "p")
        XCTAssertTrue(mirror.isStreamed("p"))
        XCTAssertEqual(mirror.histories["p"], PaneHistory(lines: lines(1...40)))
        // One that does not replaces them.
        XCTAssertTrue(mirror.extend(paneID: "p", scrolledOff: nil, reset: true))
        mirror.receive(lines(100...120), paneID: "p")
        XCTAssertEqual(mirror.histories["p"], PaneHistory(lines: lines(100...120)))
        // One that reaches further back than the shown rows replaces them while the pane is not read.
        XCTAssertTrue(mirror.extend(paneID: "p", scrolledOff: nil, reset: true))
        mirror.receive(lines(90...125), paneID: "p")
        XCTAssertEqual(mirror.histories["p"], PaneHistory(lines: lines(90...125)))
    }

    func testKeepsAtMostMaxRows() {
        var mirror = HistoryMirror()
        mirror.connected(streams: true)
        mirror.receive(lines(1...10), paneID: "p")
        _ = mirror.extend(paneID: "p", scrolledOff: lines(11...(HistoryMirror.maxRows + 5)), reset: false)
        XCTAssertEqual(mirror.histories["p"]?.lines.count, HistoryMirror.maxRows)
        XCTAssertEqual(mirror.histories["p"]?.first, 5)
        XCTAssertEqual(mirror.histories["p"]?.lines.last, "line \(HistoryMirror.maxRows + 5)")
    }

    /// While a pane is read: rows are added up to `maxRowsWhileReading`, then wait, as does an answer that does not
    /// continue the shown rows; reading ends (or Latest) shows them, trimmed to `maxRows`.
    func testReadingOnlyGrowsAtTheBottom() {
        var mirror = HistoryMirror()
        mirror.connected(streams: true)
        mirror.receive(lines(1...30), paneID: "p")
        mirror.setReading(paneID: "p", true)
        let cap = HistoryMirror.maxRowsWhileReading
        _ = mirror.extend(paneID: "p", scrolledOff: lines(31...cap), reset: false)
        XCTAssertEqual(mirror.histories["p"], PaneHistory(lines: lines(1...cap)))
        // Full: the shown rows stay, the rest waits.
        _ = mirror.extend(paneID: "p", scrolledOff: lines((cap + 1)...(cap + 10)), reset: false)
        _ = mirror.extend(paneID: "p", scrolledOff: ["line \(cap + 11)"], reset: false)
        XCTAssertEqual(mirror.histories["p"], PaneHistory(lines: lines(1...cap)))
        mirror.setReading(paneID: "p", false)
        XCTAssertEqual(mirror.histories["p"]?.lines, lines((cap + 12 - HistoryMirror.maxRows)...(cap + 11)))
        XCTAssertEqual(mirror.histories["p"]?.first, cap + 11 - HistoryMirror.maxRows)

        // A reset while reading: an answer that does not continue the rows waits for the end of reading.
        mirror.setReading(paneID: "p", true)
        XCTAssertTrue(mirror.extend(paneID: "p", scrolledOff: nil, reset: true))
        mirror.receive(["after clear"], paneID: "p")
        _ = mirror.extend(paneID: "p", scrolledOff: ["more"], reset: false)
        XCTAssertEqual(mirror.histories["p"]?.lines.last, "line \(cap + 11)")
        // Latest shows them while the pane still counts as read.
        mirror.showPending("p")
        XCTAssertEqual(mirror.histories["p"], PaneHistory(lines: ["after clear", "more"]))
        _ = mirror.extend(paneID: "p", scrolledOff: lines(1...(HistoryMirror.maxRows + 10)), reset: false)
        XCTAssertEqual(mirror.histories["p"]?.lines.count, HistoryMirror.maxRows + 12)
        mirror.setReading(paneID: "p", false)
        XCTAssertEqual(mirror.histories["p"]?.lines.count, HistoryMirror.maxRows)
        // Not reading any more: setReading(false) again changes nothing.
        let shown = mirror.histories["p"]
        mirror.setReading(paneID: "p", false)
        XCTAssertEqual(mirror.histories["p"], shown)
    }

    func testReadingAnswerThatContinuesIsAppended() {
        var mirror = HistoryMirror()
        mirror.connected(streams: true)
        mirror.receive(lines(1...30), paneID: "p")
        mirror.setReading(paneID: "p", true)
        XCTAssertTrue(mirror.extend(paneID: "p", scrolledOff: nil, reset: true))
        // Reaches further back, but continues the rows being read: added below them.
        mirror.receive(lines(1...35), paneID: "p")
        XCTAssertEqual(mirror.histories["p"], PaneHistory(lines: lines(1...35)))
    }

    /// A new connection with a streaming Mac: rows of panes not being read are dropped; rows being read stay until
    /// reading ends, then give way to the answer (or to nothing).
    func testNewConnectionKeepsTheRowsBeingRead() {
        var mirror = HistoryMirror()
        mirror.connected(streams: true)
        mirror.receive(lines(1...30), paneID: "read")
        mirror.receive(lines(1...30), paneID: "other")
        mirror.setReading(paneID: "read", true)
        mirror.connected(streams: true)
        XCTAssertFalse(mirror.isStreamed("read"))
        XCTAssertNil(mirror.histories["other"])
        XCTAssertEqual(mirror.histories["read"], PaneHistory(lines: lines(1...30)))
        mirror.receive(lines(5...40), paneID: "read")
        XCTAssertEqual(mirror.histories["read"], PaneHistory(lines: lines(1...40)))

        // Reading ends before the answer: nothing above the screen until it comes.
        mirror.connected(streams: true)
        mirror.setReading(paneID: "read", false)
        XCTAssertEqual(mirror.histories["read"], PaneHistory())
    }

    func testForgetsGonePanes() {
        var mirror = HistoryMirror()
        mirror.connected(streams: true)
        mirror.receive(lines(1...30), paneID: "a")
        mirror.receive(lines(1...30), paneID: "b")
        mirror.setReading(paneID: "a", true)
        mirror.forget { $0 == "a" }
        XCTAssertNil(mirror.histories["a"])
        XCTAssertFalse(mirror.isStreamed("a"))
        XCTAssertTrue(mirror.isStreamed("b"))
        // No longer read either: a new answer is shown at once.
        mirror.receive(lines(1...5), paneID: "a")
        XCTAssertEqual(mirror.histories["a"], PaneHistory(lines: lines(1...5)))
    }
}
