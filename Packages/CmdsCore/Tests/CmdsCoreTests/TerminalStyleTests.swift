import XCTest
@testable import CmdsCore

/// A row read as VT text (`ghostty_surface_read_text_vt`) → its plain text and style runs (#113). The inputs are what
/// Ghostty's formatter writes: every style starts with `ESC[0m`, one attribute per SGR, `ESC[0m` back to the default,
/// CUF over blank cells, ECH + CUF for cells that only carry a background.
final class TerminalStyleTests: XCTestCase {
    private func parse(_ vt: String) -> StyledRow { TerminalStyledText.parse(vt) }
    private func run(_ column: Int, _ length: Int, _ attributes: TerminalStyle.Attributes = [],
                     fg: TerminalColor? = nil, bg: TerminalColor? = nil) -> StyleRun {
        StyleRun(column: column, length: length, style: TerminalStyle(attributes: attributes, foreground: fg, background: bg))
    }

    func testPlainTextHasNoRuns() {
        XCTAssertEqual(parse("$ ls -la").text, "$ ls -la")
        XCTAssertEqual(parse("$ ls -la").runs, [])
        XCTAssertEqual(parse("").text, "")
    }

    func testPaletteColoursAndAttributes() {
        let row = parse("\u{1B}[0m\u{1B}[1m\u{1B}[38;5;2muser\u{1B}[0m:\u{1B}[0m\u{1B}[38;5;12m~/src\u{1B}[0m$ ")
        XCTAssertEqual(row.text, "user:~/src$ ")
        XCTAssertEqual(row.runs, [run(0, 4, .bold, fg: .palette(2)), run(5, 5, fg: .palette(12))])
    }

    func testRGBAndBackgroundAndInverse() {
        let row = parse("\u{1B}[0m\u{1B}[7m\u{1B}[38;2;255;128;0m\u{1B}[48;2;0;0;64m NORMAL \u{1B}[0m x")
        XCTAssertEqual(row.text, " NORMAL  x")
        XCTAssertEqual(row.runs, [run(0, 8, .inverse, fg: .rgb(255, 128, 0), bg: .rgb(0, 0, 64))])
    }

    func testEveryAttribute() {
        let row = parse("\u{1B}[0m\u{1B}[1m\u{1B}[2m\u{1B}[3m\u{1B}[5m\u{1B}[7m\u{1B}[8m\u{1B}[9m\u{1B}[53m\u{1B}[4:3mx")
        XCTAssertEqual(row.runs, [run(0, 1, [.bold, .faint, .italic, .inverse, .invisible, .strikethrough, .underline])])
        XCTAssertEqual(parse("\u{1B}[4ma\u{1B}[4:0mb\u{1B}[21mc\u{1B}[24md").runs,
                       [run(0, 1, .underline), run(2, 1, .underline)])
    }

    /// Other programs' forms, in case they reach the parser: classic 30–37/90–97, combined parameters, `:` colours.
    func testClassicAndCombinedSGR() {
        XCTAssertEqual(parse("\u{1B}[31ma\u{1B}[1;94;43mb\u{1B}[22;39;49mc\u{1B}[mz").runs,
                       [run(0, 1, fg: .palette(1)), run(1, 1, .bold, fg: .palette(12), bg: .palette(3))])
        XCTAssertEqual(parse("\u{1B}[38:2::10:20:30ma\u{1B}[48:5:200mb").runs,
                       [run(0, 1, fg: .rgb(10, 20, 30)), run(1, 1, fg: .rgb(10, 20, 30), bg: .palette(200))])
        XCTAssertEqual(parse("\u{1B}[58;5;1ma\u{1B}[38;5;3;1mb").runs, [run(1, 1, .bold, fg: .palette(3))])
        XCTAssertEqual(parse("\u{1B}[100ma\u{1B}[0mb").runs, [run(0, 1, bg: .palette(8))])
    }

    /// Blank cells are stepped over (CUF): spaces in the text, plain, also right after a styled run.
    func testBlankCellsAreSpaces() {
        let row = parse("\u{1B}[0m\u{1B}[38;5;1merror\u{1B}[3Cx")
        XCTAssertEqual(row.text, "error   x")
        XCTAssertEqual(row.runs, [run(0, 5, fg: .palette(1)), run(8, 1, fg: .palette(1))])
        XCTAssertEqual(parse("\u{1B}[4Cx").text, "    x")
    }

    /// Cells that only carry a background (erased while one was set): ECH then CUF over them; they keep the
    /// background, also past the last text (a status bar up to the right edge).
    func testBackgroundOnlyCells() {
        let row = parse("\u{1B}[0m\u{1B}[48;5;4m\u{1B}[0m\u{1B}[48;5;4mmain\u{1B}[6X\u{1B}[6C\u{1B}[0m")
        XCTAssertEqual(row.text, "main      ")
        XCTAssertEqual(row.runs, [run(0, 10, bg: .palette(4))])
        let between = parse("a\u{1B}[0m\u{1B}[48;5;1m\u{1B}[2X\u{1B}[2C\u{1B}[0mb")
        XCTAssertEqual(between.text, "a  b")
        XCTAssertEqual(between.runs, [run(1, 2, bg: .palette(1))])
    }

    /// Columns count cells like the phone's grid (`TerminalCells`): a wide character takes two.
    func testWideCharactersTakeTwoColumns() {
        let row = parse("日本\u{1B}[0m\u{1B}[38;5;3m語\u{1B}[0m \u{1B}[0m\u{1B}[1m🚀x")
        XCTAssertEqual(row.text, "日本語 🚀x")
        XCTAssertEqual(row.runs, [run(4, 2, fg: .palette(3)), run(7, 3, .bold)])
    }

    /// OSC 8 hyperlinks (BEL or ST) and other sequences draw nothing; CR is dropped and LF is a space, as in the
    /// plain read.
    func testOtherSequencesAreSkipped() {
        let row = parse("\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\ \u{1B}]8;;x\u{07}y\u{1B}[?25h\r\nz")
        XCTAssertEqual(row.text, "link y z")
        XCTAssertEqual(row.runs, [])
        XCTAssertEqual(parse("a\u{1B}").text, "a")
        XCTAssertEqual(parse("a\u{1B}[").text, "a")
    }

    func testAdjacentRunsOfTheSameStyleMerge() {
        XCTAssertEqual(parse("\u{1B}[0m\u{1B}[1mab\u{1B}[0m\u{1B}[1mcd").runs, [run(0, 4, .bold)])
    }

    func testRunWireFormat() throws {
        let runs = [run(0, 4, .bold), run(6, 3, fg: .palette(1)), run(0, 80, .inverse, bg: .palette(4)),
                    run(2, 1, fg: .rgb(255, 0, 16)), run(3, 2)]
        let data = try JSONEncoder().encode(runs)
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       "[[0,4,1],[6,3,0,1],[0,80,16,-1,4],[2,1,0,33488912],[3,2]]")
        XCTAssertEqual(try JSONDecoder().decode([StyleRun].self, from: data), runs)
        // Unknown attribute bits and colour values from a newer Mac are dropped, not fatal.
        XCTAssertEqual(try JSONDecoder().decode([StyleRun].self, from: Data("[[1,2,1025,999,-5]]".utf8)),
                       [run(1, 2, .bold)])
        XCTAssertThrowsError(try JSONDecoder().decode([StyleRun].self, from: Data("[[1,0]]".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode([StyleRun].self, from: Data("[[1]]".utf8)))
    }
}

/// The phone's colours for palette indexes and RGB.
final class TerminalPaletteTests: XCTestCase {
    func testPaletteIndexes() {
        typealias RGB = TerminalPalette.RGB
        XCTAssertEqual(TerminalPalette.rgb(.palette(1)), TerminalPalette.ansi[1])
        XCTAssertEqual(TerminalPalette.rgb(.palette(15)), RGB(255, 255, 255))
        XCTAssertEqual(TerminalPalette.rgb(.palette(16)), RGB(0, 0, 0))
        XCTAssertEqual(TerminalPalette.rgb(.palette(196)), RGB(255, 0, 0))
        XCTAssertEqual(TerminalPalette.rgb(.palette(208)), RGB(255, 135, 0))
        XCTAssertEqual(TerminalPalette.rgb(.palette(231)), RGB(255, 255, 255))
        XCTAssertEqual(TerminalPalette.rgb(.palette(232)), RGB(8, 8, 8))
        XCTAssertEqual(TerminalPalette.rgb(.palette(255)), RGB(238, 238, 238))
        XCTAssertEqual(TerminalPalette.rgb(.rgb(1, 2, 3)), RGB(1, 2, 3))
        XCTAssertEqual(TerminalPalette.ansi.count, 16)
    }
}
