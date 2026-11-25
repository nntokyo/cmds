import XCTest
@testable import CmdsCore

/// Text a person typed into an agent's input box keeps cmds from typing into the pane (`AgentInputBox`).
final class AgentInputBoxTests: XCTestCase {
    private let rule = String(repeating: "─", count: 60)
    private let faint = TerminalStyle(attributes: .faint, foreground: nil, background: nil)
    private let inverse = TerminalStyle(attributes: .inverse, foreground: nil, background: nil)

    /// Claude Code's screen: output, the input box between two rules, the status line.
    private func claude(_ input: [String]) -> [String] {
        ["⏺ Done.", "", rule] + input + [rule, "  ⏵⏵ bypass permissions on (shift+tab to cycle)"]
    }

    private func runs(_ rows: [String], _ styled: [Int: [StyleRun]]) -> [[StyleRun]] {
        rows.indices.map { styled[$0] ?? [] }
    }

    func testEmptyClaudeBox() {
        XCTAssertFalse(AgentInputBox.hasTypedText(rows: claude(["❯ "])))
        XCTAssertFalse(AgentInputBox.hasTypedText(rows: claude(["❯"]), runs: runs(claude(["❯"]), [:])))
    }

    func testTypedTextInClaudeBox() {
        let rows = claude(["❯ fix the login page"])
        XCTAssertTrue(AgentInputBox.hasTypedText(rows: rows))
        XCTAssertTrue(AgentInputBox.hasTypedText(rows: rows, runs: runs(rows, [:])))
    }

    func testLaterRowsOfALongTextCount() {
        let rows = claude(["❯ ", "  second line"])
        XCTAssertTrue(AgentInputBox.hasTypedText(rows: rows, runs: runs(rows, [:])))
    }

    func testOtherModesOfTheBox() {
        for mark in ["!", "#", ">"] {
            XCTAssertTrue(AgentInputBox.hasTypedText(rows: claude(["\(mark) ls -la"])), mark)
            XCTAssertFalse(AgentInputBox.hasTypedText(rows: claude(["\(mark) "])), mark)
        }
    }

    /// A placeholder: the cursor block over its first character (inverse), the rest faint.
    func testPlaceholderIsNotTypedText() {
        let rows = claude(["❯ Try \"fix lint errors\""])
        let styled = runs(rows, [3: [StyleRun(column: 2, length: 1, style: inverse), StyleRun(column: 3, length: 20, style: faint)]])
        XCTAssertFalse(AgentInputBox.hasTypedText(rows: rows, runs: styled))
        // Without styles the text cannot be told from typed text: the safe side.
        XCTAssertTrue(AgentInputBox.hasTypedText(rows: rows))
    }

    func testGreyPlaceholderColours() {
        let rows = claude(["❯ run the tests"])
        for colour in [TerminalColor.palette(8), .palette(244), .rgb(128, 128, 128)] {
            let grey = TerminalStyle(attributes: [], foreground: colour, background: nil)
            XCTAssertFalse(AgentInputBox.hasTypedText(rows: rows, runs: runs(rows, [3: [StyleRun(column: 2, length: 13, style: grey)]])))
        }
        // Coloured typed text (a slash command, a file mention) is typed text; so is white.
        for colour in [TerminalColor.palette(4), .rgb(177, 185, 249), .rgb(255, 255, 255)] {
            let style = TerminalStyle(attributes: [], foreground: colour, background: nil)
            XCTAssertTrue(AgentInputBox.hasTypedText(rows: rows, runs: runs(rows, [3: [StyleRun(column: 2, length: 13, style: style)]])))
        }
    }

    /// Typed text after a faint part (a suggestion completing what was typed) still counts.
    func testTypedTextBesideAFaintPart() {
        let rows = claude(["❯ run the tests"])
        XCTAssertTrue(AgentInputBox.hasTypedText(rows: rows, runs: runs(rows, [3: [StyleRun(column: 6, length: 9, style: faint)]])))
    }

    /// Columns count cells: a wide character takes two.
    func testWideCharactersKeepColumns() {
        let rows = claude(["❯ 日本語のテキスト"])
        XCTAssertFalse(AgentInputBox.hasTypedText(rows: rows, runs: runs(rows, [3: [StyleRun(column: 2, length: 16, style: faint)]])))
        XCTAssertTrue(AgentInputBox.hasTypedText(rows: rows, runs: runs(rows, [3: [StyleRun(column: 2, length: 8, style: faint)]])))
    }

    func testRulesInOutputAreNotABox() {
        // Two rules around output, no prompt mark: not an input box.
        let rows = ["⏺ Report", rule, "  Summary of the work", rule, ""]
        XCTAssertFalse(AgentInputBox.hasTypedText(rows: rows))
        // The box is between the last two rules, whatever is above.
        let below = ["⏺ Report", rule, "  Summary of the work", rule, "❯ ", rule]
        XCTAssertFalse(AgentInputBox.hasTypedText(rows: below))
        XCTAssertTrue(AgentInputBox.hasTypedText(rows: ["  text", rule, "❯ typed", rule]))
    }

    /// Claude Code's folder trust question: choices without numbers, "No, exit" selected. Return would answer it.
    func testTrustQuestionHasNoBox() {
        let rows = [rule, " Accessing workspace:", " /tmp/project", " Quick safety check: Is this a project you created or one you trust?",
                    " ❯ No, exit", "   Yes, I trust this folder", " Enter to confirm · Esc to cancel"]
        XCTAssertEqual(AgentInputBox.state(rows: rows), .missing)
        XCTAssertFalse(ScheduleRunTiming.showsChoice(screen: rows.joined(separator: "\n")), "the numbered-choice check does not see it")
        XCTAssertEqual(AgentInputBox.state(rows: claude(["❯ "])), .empty)
        XCTAssertEqual(AgentInputBox.state(rows: claude(["❯ text"])), .typed)
    }

    func testNoBoxOnScreen() {
        XCTAssertFalse(AgentInputBox.hasTypedText(rows: []))
        XCTAssertFalse(AgentInputBox.hasTypedText(rows: ["user@mac ~ % ls", "file.txt"]))
    }

    func testCodexPromptRow() {
        let empty = ["• Done.", "", "› ", "", "  gpt-5 · 12% context left"]
        XCTAssertFalse(AgentInputBox.hasTypedText(rows: empty))
        let typed = ["• Done.", "", "› add a test for it", "", "  gpt-5 · 12% context left"]
        XCTAssertTrue(AgentInputBox.hasTypedText(rows: typed, runs: runs(typed, [:])))
        let placeholder = ["• Done.", "", "› Ask Codex to do anything", "", "  gpt-5 · 12% context left"]
        XCTAssertFalse(AgentInputBox.hasTypedText(rows: placeholder, runs: runs(placeholder, [2: [StyleRun(column: 2, length: 25, style: faint)]])))
    }
}
