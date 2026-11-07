import Foundation
import XCTest
@testable import CmdsCore

/// Colours and attributes of terminal rows (`SyncFeature.styles`, #113) end to end against an isolated instance
/// (docs/internals/testing.md "Sync against an isolated instance"): set `CMDS_STYLES_E2E_PAIRING` to its
/// `sync-test-pairing.txt`. The test opens its own workspace through the instance's socket, prints coloured rows there,
/// pairs two phones (with and without the feature) and checks what each gets. It types only into the pane it created
/// and closes that workspace at the end.
final class SyncStylesE2ETests: XCTestCase {
    func testStylesFromIsolatedInstance() throws {
        let instance = try SyncE2EInstance(pairingVariable: "CMDS_STYLES_E2E_PAIRING")
        let (workspaceID, paneID) = try instance.createWorkspace(title: "styles e2e")
        defer { instance.closeWorkspace(workspaceID) }
        // `clear` first, so only these rows and the prompt are on the screen. The text after `printf` reads differently
        // in the command line (escapes as typed), so its output rows are found by their text.
        try instance.type("clear; printf '"
                          + #"\033[1m\033[31mERROR\033[0m plain \033[38;5;208morange\033[0m "#
                          + #"\033[38;2;10;20;30mrgb\033[0m \033[7minv\033[0m 日本\033[4mUL\033[0m\n"#
                          + #"\033[44mbar\033[K\033[0m\n"#
                          + #"\033[2mfaint\033[0m \033[3mitalic\033[0m \033[9mstrike\033[0m \033[42m  \033[0m end\n"#
                          + "'\n", into: paneID)

        let phone = try SyncE2EPhone(instance, hello: .init(deviceName: "styles test", deviceID: "styles-test",
                                                            features: [SyncFeature.styles],
                                                            pairingCode: instance.payload.code))
        XCTAssertEqual(phone.welcome.features?.contains(SyncFeature.styles), true)
        try phone.send(.subscribe(.init(paneIDs: [paneID])))
        let first = "ERROR plain orange rgb inv 日本UL"
        try phone.wait(for: paneID) { $0.lines.contains("faint italic strike    end") && $0.lines.contains(first) }
        let screen = try XCTUnwrap(phone.mirror[paneID])

        func runs(of text: String) throws -> [StyleRun] {
            screen.runs(row: try XCTUnwrap(screen.lines.firstIndex(of: text), text))
        }
        func run(_ column: Int, _ length: Int, _ attributes: TerminalStyle.Attributes = [],
                 fg: TerminalColor? = nil, bg: TerminalColor? = nil) -> StyleRun {
            StyleRun(column: column, length: length,
                     style: TerminalStyle(attributes: attributes, foreground: fg, background: bg))
        }
        // Palette colours stay indexes; columns count the wide characters as two cells.
        XCTAssertEqual(try runs(of: first), [
            run(0, 5, .bold, fg: .palette(1)), run(12, 6, fg: .palette(208)), run(19, 3, fg: .rgb(10, 20, 30)),
            run(23, 3, .inverse), run(31, 2, .underline),
        ])
        // A background erased to the right edge reaches it, past the text.
        XCTAssertEqual(try runs(of: "bar"), [run(0, screen.cols, bg: .palette(4))])
        XCTAssertEqual(try runs(of: "faint italic strike    end"), [
            run(0, 5, .faint), run(6, 6, .italic), run(13, 6, .strikethrough), run(20, 2, bg: .palette(2)),
        ])

        // The text is what `cmds read` gives (the plain read), trailing spaces aside.
        let plain = try instance.api.call("pane.read_text", params: ["pane": .string(paneID)])["text"]?.stringValue ?? ""
        let plainRows = plain.components(separatedBy: "\n").map { $0.replacingOccurrences(of: " +$", with: "",
                                                                                         options: .regularExpression) }
        for row in [first, "bar", "faint italic strike    end"] { XCTAssertTrue(plainRows.contains(row), row) }

        // A phone without the feature gets the same text and no styles.
        let older = try SyncE2EPhone(instance, hello: .init(deviceName: "plain test", deviceID: "plain-test",
                                                            token: phone.welcome.token))
        try older.send(.subscribe(.init(paneIDs: [paneID])))
        try older.wait(for: paneID) { $0.lines.contains(first) }
        XCTAssertNil(older.mirror[paneID]?.styles)
        XCTAssertEqual(older.mirror[paneID]?.lines, screen.lines)

        // New output reaches both; a row's runs change with it in a diff.
        try instance.type("printf '\\033[32mok\\033[0m\\n'\n", into: paneID)
        try phone.wait(for: paneID) { s in s.lines.firstIndex(of: "ok").map { s.runs(row: $0) == [run(0, 2, fg: .palette(2))] } == true }
        try older.wait(for: paneID) { $0.lines.contains("ok") }
        XCTAssertNil(older.mirror[paneID]?.styles)
    }

    /// The rows above the screen keep their styles: in the `scrollback` answer (`styles`) and in the rows that scroll
    /// off afterwards (`scrolledOffStyles`), for a phone with `styles` and `scrollbackStream`; a phone without
    /// `styles` gets the same rows plain.
    func testHistoryStylesFromIsolatedInstance() throws {
        let instance = try SyncE2EInstance(pairingVariable: "CMDS_STYLES_E2E_PAIRING")
        let (workspaceID, paneID) = try instance.createWorkspace(title: "styles history e2e")
        defer { instance.closeWorkspace(workspaceID) }
        // Numbered rows, every third one red and bold from column 4: `n  r` with n right-aligned in 3 columns.
        func printRows(_ range: ClosedRange<Int>) throws {
            try instance.type("for i in {\(range.lowerBound)..\(range.upperBound)}; do if (( i % 3 == 0 )); then "
                              + #"printf '%3d \033[1;31mred\033[0m\n' $i; else printf '%3d plain\n' $i; fi; done"#
                              + "\n", into: paneID)
        }
        try printRows(1...200)

        let phone = try SyncE2EPhone(instance, hello: .init(
            deviceName: "styles history test", deviceID: "styles-history-test",
            features: [SyncFeature.styles, SyncFeature.scrollbackStream], pairingCode: instance.payload.code))
        let plain = try SyncE2EPhone(instance, hello: .init(deviceName: "plain history test",
                                                            deviceID: "plain-history-test",
                                                            features: [SyncFeature.scrollbackStream],
                                                            token: phone.welcome.token))
        let red = StyleRun(column: 4, length: 3,
                           style: TerminalStyle(attributes: .bold, foreground: .palette(1)))
        func check(_ rows: [(text: String, runs: [StyleRun])], file: StaticString = #filePath, line: UInt = #line) {
            var checked = 0
            for row in rows {
                let parts = row.text.split(separator: " ")
                guard parts.count == 2, let n = Int(parts[0]) else { continue }
                XCTAssertEqual(row.runs, n % 3 == 0 ? [red] : [], row.text, file: file, line: line)
                checked += 1
            }
            XCTAssertGreaterThan(checked, 10, "numbered rows", file: file, line: line)
        }

        for p in [phone, plain] {
            try p.send(.subscribe(.init(paneIDs: [paneID])))
            try p.wait(for: paneID) { $0.lines.contains(where: { $0.hasPrefix("200 ") }) }
            try p.send(.requestScrollback(.init(paneID: paneID, lines: 150)))
        }
        let (_, rows) = try phone.scrollback(paneID)
        let answered = PaneHistory(lines: rows, styles: phone.lastScrollbackStyles)
        check(rows.indices.map { (rows[$0], answered.runs(row: $0)) })
        let (_, plainRows) = try plain.scrollback(paneID)
        XCTAssertEqual(plainRows, rows)
        XCTAssertNil(plain.lastScrollbackStyles)

        // Rows that scroll off from now on come with their runs.
        try printRows(201...300)
        try phone.wait(for: paneID) { $0.lines.contains(where: { $0.hasPrefix("300 ") }) }
        while !phone.scrolledOffRows.contains(where: { $0.text.hasPrefix("230 ") }) { _ = try phone.next() }
        check(phone.scrolledOffRows)
        try plain.wait(for: paneID) { $0.lines.contains(where: { $0.hasPrefix("300 ") }) }
        while !plain.scrolledOffRows.contains(where: { $0.text.hasPrefix("230 ") }) { _ = try plain.next() }
        XCTAssertTrue(plain.scrolledOffRows.allSatisfy { $0.runs.isEmpty })
    }
}
