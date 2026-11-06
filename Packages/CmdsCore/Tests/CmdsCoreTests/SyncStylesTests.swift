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

    func testFeatureName() {
        XCTAssertEqual(SyncFeature.styles, "styles")
    }
}
