import XCTest
@testable import CmdsCore

/// Cells per character, for laying the phone's rows out on the terminal grid (#115).
final class TerminalCellsTests: XCTestCase {
    func testNarrowCharactersTakeOneCell() {
        for character in ["a", "Z", "0", " ", "~", "é", "→", "─", "λ"] as [Character] {
            XCTAssertEqual(TerminalCells.width(of: character), 1, String(character))
        }
    }

    func testWideCharactersTakeTwoCells() {
        for character in ["日", "本", "あ", "ア", "한", "，", "Ａ", "　", "🚀", "😀", "🧪", "𠮷"] as [Character] {
            XCTAssertEqual(TerminalCells.width(of: character), 2, String(character))
        }
    }

    func testTextWidthAddsCells() {
        XCTAssertEqual(TerminalCells.width(of: ""), 0)
        XCTAssertEqual(TerminalCells.width(of: "ls -la"), 6)
        XCTAssertEqual(TerminalCells.width(of: "日本語 abc"), 10)
    }
}
