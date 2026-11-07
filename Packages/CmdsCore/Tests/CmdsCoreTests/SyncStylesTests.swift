import XCTest
@testable import CmdsCore

/// Colours and attributes of terminal rows in `screen` / `screenDiff` (`SyncFeature.styles`, #113).
final class SyncStylesTests: XCTestCase {
    let codec = SyncCodec()
    private let red = StyleRun(column: 0, length: 5, style: TerminalStyle(foreground: .palette(1)))
    private let bold = StyleRun(column: 2, length: 3, style: TerminalStyle(attributes: .bold))
    private let bar = StyleRun(column: 0, length: 20, style: TerminalStyle(attributes: .inverse, background: .rgb(1, 2, 3)))

    private func snapshot(_ lines: [String], styles: [[StyleRun]]? = nil, cursorRow: Int? = nil) -> ScreenSnapshot {
        ScreenSnapshot(rows: lines.count, cols: 20, lines: lines, cursorRow: cursorRow, cursorCol: 0, styles: styles)
    }

    func testSnapshotKeepsStylesNormalized() {
        XCTAssertNil(snapshot(["a", "b"], styles: [[], []]).styles)
        XCTAssertEqual(snapshot(["a", "b"], styles: [[], []]), snapshot(["a", "b"]))
        XCTAssertEqual(snapshot(["a", "b", "c"], styles: [[red]]).styles, [[red], [], []])
        var s = snapshot(["a", "b"])
        s.setRuns([bold], row: 1)
        XCTAssertEqual(s.runs(row: 1), [bold])
        XCTAssertEqual(s.rowStyles, [RowStyle(row: 1, runs: [bold])])
        s.setRuns(nil, row: 1)
        XCTAssertNil(s.styles)
        XCTAssertNil(s.rowStyles)
        s.setRuns([bold], row: 9) // out of range: ignored
        XCTAssertNil(s.styles)
        XCTAssertEqual(snapshot(["a"], styles: [[red]]).withoutStyles, snapshot(["a"]))
    }

    /// Only rows with runs are sent; the phone rebuilds the same snapshot.
    func testScreenRoundTrip() throws {
        let s = snapshot(["error: x", "", "NORMAL"], styles: [[red, bold], [], [bar]], cursorRow: 1)
        let message = ServerMessage.screen(.init(paneID: "p1", seq: 3, snapshot: s))
        let data = try codec.encode(message)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains(#""styles":[{"row":0,"runs":[[0,5,0,1],[2,3,1]]},{"row":2,"runs":[[0,20,16,-1,16843267]]}]"#), json)
        XCTAssertEqual(try codec.decodeServerMessage(data), message)
        guard case .screen(let decoded) = try codec.decodeServerMessage(data) else { return XCTFail() }
        XCTAssertEqual(decoded.snapshot, s)
    }

    func testDiffRoundTrip() throws {
        let diff = ServerMessage.screenDiff(.init(paneID: "p1", seq: 4, baseSeq: 3, changes: [
            LineChange(row: 0, text: "ok", runs: [red]), LineChange(row: 2, text: "plain"),
        ]))
        let data = try codec.encode(diff)
        XCTAssertEqual(try codec.decodeServerMessage(data), diff)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#"{"row":2,"text":"plain"}"#))
    }

    /// A plain screen keeps the wire format of Macs before styles: no `styles` / `runs` keys.
    func testPlainScreensKeepTheOldWireFormat() throws {
        let s = snapshot(["a", "b"])
        var streamer = ScreenStreamer()
        let first = try XCTUnwrap(streamer.update(paneID: "p", snapshot: s))
        var changed = s
        changed.lines[1] = "c"
        let second = try XCTUnwrap(streamer.update(paneID: "p", snapshot: changed))
        for message in [first, second] {
            let json = String(decoding: try codec.encode(message), as: UTF8.self)
            XCTAssertFalse(json.contains("styles") || json.contains("runs"), json)
        }
    }

    /// An older phone decodes only the fields it knows: same text, the new keys ignored. A newer phone reading an older
    /// Mac gets no styles.
    func testOlderPeersInteroperate() throws {
        struct OldChange: Decodable, Equatable { var row: Int; var text: String }
        struct OldScreen: Decodable { var type: String; var seq: UInt64; var lines: [String]; var changes: [OldChange]? }
        let screen = ServerMessage.screen(.init(paneID: "p", seq: 1, snapshot: snapshot(["x"], styles: [[red]])))
        let old = try JSONDecoder().decode(OldScreen.self, from: try codec.encode(screen))
        XCTAssertEqual(old.lines, ["x"])
        let diff = ServerMessage.screenDiff(.init(paneID: "p", seq: 2, baseSeq: 1,
                                                  changes: [LineChange(row: 0, text: "y", runs: [bold])]))
        struct OldDiff: Decodable { var changes: [OldChange] }
        XCTAssertEqual(try JSONDecoder().decode(OldDiff.self, from: try codec.encode(diff)).changes,
                       [OldChange(row: 0, text: "y")])

        let fromOldMac = #"{"type":"screen","paneID":"p","seq":1,"rows":1,"cols":5,"lines":["hi"]}"#
        guard case .screen(let decoded) = try codec.decodeServerMessage(Data(fromOldMac.utf8)) else { return XCTFail() }
        XCTAssertNil(decoded.styles)
        XCTAssertNil(decoded.snapshot.styles)
    }

    /// A row whose runs changed but not its text is a change; its runs go with it, nil when it became plain.
    func testDiffCoversStyleOnlyChanges() throws {
        let s1 = snapshot(["a", "b", "c"], styles: [[red], [], []])
        let s2 = snapshot(["a", "b", "c"], styles: [[], [bold], []])
        let changes = try XCTUnwrap(ScreenDiffer.diff(from: s1, to: s2))
        XCTAssertEqual(changes, [LineChange(row: 0, text: "a"), LineChange(row: 1, text: "b", runs: [bold])])
        XCTAssertEqual(try ScreenDiffer.apply(changes, to: s1), s2)
        XCTAssertEqual(ScreenDiffer.diff(from: s2, to: s2), [])
        XCTAssertEqual(ScreenDiffer.diff(from: snapshot(["a"]), to: snapshot(["b"])), [LineChange(row: 0, text: "b")])
        XCTAssertNil(ScreenDiffer.diff(from: s1, to: snapshot(["a"])))
    }

    /// Mac → phone through the streamer and the mirror: the phone ends up with the Mac's snapshot, styles included.
    func testStreamerAndMirrorCarryStyles() throws {
        var streamer = ScreenStreamer()
        var mirror = ScreenMirror()
        func send(_ s: ScreenSnapshot) throws -> ServerMessage? {
            guard let message = streamer.update(paneID: "p", snapshot: s) else { return nil }
            let decoded = try codec.decodeServerMessage(try codec.encode(message))
            switch decoded {
            case .screen(let screen): XCTAssertEqual(mirror.apply(screen), .updated(paneID: "p"))
            case .screenDiff(let diff): XCTAssertEqual(mirror.apply(diff), .updated(paneID: "p"))
            default: XCTFail("\(decoded)")
            }
            XCTAssertEqual(mirror["p"], s)
            return decoded
        }
        let lines = (0..<10).map { "row \($0) with some text" }
        let s1 = snapshot(lines, styles: [[red]])
        guard case .screen = try send(s1) else { return XCTFail() }
        var s2 = s1
        s2.setRuns([bold], row: 4)
        guard case .screenDiff(let diff) = try send(s2) else { return XCTFail() }
        XCTAssertEqual(diff.changes, [LineChange(row: 4, text: lines[4], runs: [bold])])
        var s3 = s2
        s3.setRuns(nil, row: 0)
        s3.setRuns(nil, row: 4)
        guard case .screenDiff = try send(s3) else { return XCTFail() }
        XCTAssertNil(mirror["p"]?.styles)
        XCTAssertNil(try send(s3))
    }

    /// The Mac strips styles for phones without the feature (`withoutStyles`): a style-only change sends nothing.
    func testPhonesWithoutTheFeatureSeeNoStyleOnlyChange() {
        var streamer = ScreenStreamer()
        let s1 = snapshot(["a"], styles: [[red]])
        XCTAssertNotNil(streamer.update(paneID: "p", snapshot: s1.withoutStyles))
        XCTAssertNil(streamer.update(paneID: "p", snapshot: snapshot(["a"], styles: [[bold]]).withoutStyles))
    }

    /// `scrollback.styles` and `scrolledOffStyles` round trip; without runs the keys are left out.
    func testHistoryStylesRoundTrip() throws {
        let messages: [ServerMessage] = [
            .scrollback(.init(paneID: "p", seq: 2, lines: ["a", "b"], styles: [RowStyle(row: 1, runs: [red])])),
            .screen(.init(paneID: "p", seq: 3, rows: 1, cols: 5, lines: ["c"]))
                .withHistory(scrolledOff: ["x", "y"], styles: [RowStyle(row: 0, runs: [bold])], reset: false),
            .screenDiff(.init(paneID: "p", seq: 4, baseSeq: 3, changes: []))
                .withHistory(scrolledOff: ["z"], styles: [RowStyle(row: 0, runs: [bar])], reset: false),
        ]
        for message in messages {
            XCTAssertEqual(try codec.decodeServerMessage(try codec.encode(message)), message)
        }
        let plain = ServerMessage.scrollback(.init(paneID: "p", seq: 2, lines: ["a"]))
        XCTAssertFalse(String(decoding: try codec.encode(plain), as: UTF8.self).contains("styles"))
        // A reset carries no rows and so no runs.
        guard case .screen(let reset) = messages[1].withHistory(scrolledOff: nil, styles: [RowStyle(row: 0, runs: [red])],
                                                                reset: true) else { return XCTFail() }
        XCTAssertNil(reset.scrolledOffStyles)
    }

    /// The phone keeps the runs of the rows above the screen by row number: from the answer, from `scrolledOff`, across
    /// dropping the oldest rows, when an answer after a reset continues the rows, and when it replaces them.
    func testHistoryMirrorKeepsRuns() throws {
        var mirror = HistoryMirror()
        mirror.connected(streams: true)
        let answer = (0..<10).map { "row \($0)" }
        mirror.receive(answer, styles: [RowStyle(row: 0, runs: [red]), RowStyle(row: 9, runs: [bold])], paneID: "p")
        var history = try XCTUnwrap(mirror.histories["p"])
        XCTAssertEqual(history.runs(row: 0), [red])
        XCTAssertEqual(history.runs(row: 9), [bold])
        XCTAssertEqual(history.runs(row: 5), [])

        XCTAssertFalse(mirror.extend(paneID: "p", scrolledOff: ["row 10", "row 11"],
                                     styles: [RowStyle(row: 1, runs: [bar])], reset: false))
        history = try XCTUnwrap(mirror.histories["p"])
        XCTAssertEqual(history.lines.last, "row 11")
        XCTAssertEqual(history.runs(row: 11), [bar])
        XCTAssertEqual(history.runs(row: 10), [])

        // Dropping the oldest rows drops their runs; the others keep their numbers.
        var dropped = history
        dropped.dropOldest(3)
        XCTAssertEqual(dropped.runs(row: 0), [])
        XCTAssertNil(dropped.runs[0])
        XCTAssertEqual(dropped.runs(row: 9), [bold])

        // A reset, then an answer that still has the last rows: only the newer rows are added, with their own runs.
        XCTAssertTrue(mirror.extend(paneID: "p", scrolledOff: nil, reset: true))
        let again = (0..<14).map { "row \($0)" }
        mirror.receive(again, styles: [RowStyle(row: 13, runs: [red]), RowStyle(row: 0, runs: [bar])], paneID: "p")
        history = try XCTUnwrap(mirror.histories["p"])
        XCTAssertEqual(history.lines.count, 14)
        XCTAssertEqual(history.runs(row: 13), [red])
        XCTAssertEqual(history.runs(row: 0), [red], "rows already shown keep their runs")
        XCTAssertEqual(history.runs(row: 11), [bar])

        // An answer that does not continue them replaces rows and runs.
        XCTAssertTrue(mirror.extend(paneID: "p", scrolledOff: nil, reset: true))
        mirror.receive(["other"], styles: nil, paneID: "p")
        XCTAssertEqual(mirror.histories["p"], PaneHistory(lines: ["other"]))
    }

    func testFeatureName() {
        XCTAssertEqual(SyncFeature.styles, "styles")
    }
}
