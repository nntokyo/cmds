import XCTest
@testable import CmdsCore

final class SyncScreenTests: XCTestCase {
    func testDiffAndApply() throws {
        let old = ["a", "b", "c", ""]
        let new = ["a", "B", "c", "d"]
        let changes = try XCTUnwrap(ScreenDiffer.diff(from: old, to: new))
        XCTAssertEqual(changes, [LineChange(row: 1, text: "B"), LineChange(row: 3, text: "d")])
        XCTAssertEqual(try ScreenDiffer.apply(changes, to: old), new)
        XCTAssertEqual(ScreenDiffer.diff(from: new, to: new), [])
        XCTAssertNil(ScreenDiffer.diff(from: ["a"], to: ["a", "b"]))
        XCTAssertThrowsError(try ScreenDiffer.apply([LineChange(row: 9, text: "x")], to: old))
    }

    func testStreamerFullThenDiffThenNothing() throws {
        var streamer = ScreenStreamer()
        let lines = (0..<24).map { "line \($0) with some text" }
        let s1 = ScreenSnapshot(rows: 24, cols: 80, lines: lines, cursorRow: 0, cursorCol: 0)
        guard case .screen(let full) = streamer.update(paneID: "p", snapshot: s1) else { return XCTFail() }
        XCTAssertEqual(full.seq, 1)

        XCTAssertNil(streamer.update(paneID: "p", snapshot: s1))

        var s2 = s1
        s2.lines[5] = "changed"
        s2.cursorCol = 7
        guard case .screenDiff(let diff) = streamer.update(paneID: "p", snapshot: s2) else { return XCTFail() }
        XCTAssertEqual(diff.baseSeq, 1)
        XCTAssertEqual(diff.seq, 2)
        XCTAssertEqual(diff.changes, [LineChange(row: 5, text: "changed")])
        XCTAssertEqual(diff.cursorCol, 7)

        // Resize → full screen.
        let s3 = ScreenSnapshot(rows: 2, cols: 40, lines: ["x", "y"])
        guard case .screen(let resized) = streamer.update(paneID: "p", snapshot: s3) else { return XCTFail() }
        XCTAssertEqual(resized.seq, 3)

        // Everything changed → full screen even with the same size.
        let s4 = ScreenSnapshot(rows: 2, cols: 40, lines: ["1", "2"])
        guard case .screen = streamer.update(paneID: "p", snapshot: s4) else { return XCTFail() }

        // Reset keeps seq monotonic.
        streamer.reset(paneID: "p")
        guard case .screen(let again) = streamer.update(paneID: "p", snapshot: s4) else { return XCTFail() }
        XCTAssertEqual(again.seq, 5)
        guard case .screen(let requested) = streamer.fullScreen(paneID: "p") else { return XCTFail() }
        XCTAssertEqual(requested.seq, 6)
        XCTAssertNil(streamer.fullScreen(paneID: "unknown"))
    }

    func testMirrorFollowsStreamer() {
        var streamer = ScreenStreamer()
        var mirror = ScreenMirror()
        var snapshot = ScreenSnapshot(rows: 10, cols: 20, lines: Array(repeating: "", count: 10), cursorRow: 0, cursorCol: 0)
        for step in 0..<30 {
            snapshot.lines[step % 10] = "step \(step)"
            snapshot.cursorRow = step % 10
            guard let message = streamer.update(paneID: "p", snapshot: snapshot) else { continue }
            let result: ScreenMirror.ApplyResult
            switch message {
            case .screen(let s): result = mirror.apply(s)
            case .screenDiff(let d): result = mirror.apply(d)
            default: return XCTFail()
            }
            XCTAssertEqual(result, .updated(paneID: "p"))
            XCTAssertEqual(mirror["p"], snapshot)
        }
    }

    func testMirrorDetectsGapsAndStale() {
        var mirror = ScreenMirror()
        let diff = ServerMessage.ScreenDiff(paneID: "p", seq: 2, baseSeq: 1, changes: [])
        XCTAssertEqual(mirror.apply(diff), .needsFullScreen(paneID: "p"))

        XCTAssertEqual(mirror.apply(.init(paneID: "p", seq: 5, rows: 1, cols: 1, lines: ["a"])), .updated(paneID: "p"))
        XCTAssertEqual(mirror.apply(.init(paneID: "p", seq: 4, rows: 1, cols: 1, lines: ["old"])), .stale)
        XCTAssertEqual(mirror.apply(.init(paneID: "p", seq: 7, baseSeq: 6, changes: [])), .needsFullScreen(paneID: "p"))
        XCTAssertEqual(mirror.apply(.init(paneID: "p", seq: 6, baseSeq: 5, changes: [.init(row: 3, text: "x")])),
                       .needsFullScreen(paneID: "p"))
        XCTAssertEqual(mirror.apply(.init(paneID: "p", seq: 6, baseSeq: 5, changes: [.init(row: 0, text: "b")])),
                       .updated(paneID: "p"))
        XCTAssertEqual(mirror["p"]?.lines, ["b"])
    }
}
