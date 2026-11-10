import XCTest
@testable import CmdsCore

/// Choice menus that agents draw at the bottom of the screen, as the menu bar's reply panel reads them (#213).
final class AgentPromptOptionsTests: XCTestCase {
    private func parse(_ lines: [String]) -> AgentPromptOptions? {
        AgentPromptOptions.parse(lines.joined(separator: "\n"))
    }

    private func labels(_ menu: AgentPromptOptions?) -> [String] { menu?.options.map(\.label) ?? [] }

    func testClaudeCodePermissionPromptInABox() {
        let menu = parse([
            "⏺ Bash(rm -rf build)",
            "",
            "╭──────────────────────────────────────────────────────────────╮",
            "│ Bash command                                                 │",
            "│                                                              │",
            "│   rm -rf build                                               │",
            "│   Remove the build folder                                    │",
            "│                                                              │",
            "│ Do you want to proceed?                                      │",
            "│ ❯ 1. Yes                                                     │",
            "│   2. Yes, and don't ask again for rm commands in /tmp/x     │",
            "│   3. No, and tell Claude what to do differently (esc)        │",
            "╰──────────────────────────────────────────────────────────────╯",
            "",
            "",
        ])
        XCTAssertEqual(menu?.question, "Do you want to proceed?")
        XCTAssertEqual(labels(menu), ["Yes", "Yes, and don't ask again for rm commands in /tmp/x",
                                      "No, and tell Claude what to do differently (esc)"])
        XCTAssertEqual(menu?.options.map(\.number), [1, 2, 3])
        XCTAssertEqual(menu?.options.map(\.selected), [true, false, false])
    }

    func testClaudeCodePromptWithoutABoxAndWrappedLabel() {
        let menu = parse([
            "────────────────────────────────────────",
            " Edit file",
            " Do you want to make this edit to Login.swift?",
            " ❯ 1. Yes",
            "   2. Yes, allow all edits during this session",
            "      (shift+tab)",
            "   3. No, and tell Claude what to do",
            "      differently (esc)",
            "",
        ])
        XCTAssertEqual(menu?.question, "Do you want to make this edit to Login.swift?")
        XCTAssertEqual(labels(menu), ["Yes", "Yes, allow all edits during this session (shift+tab)",
                                      "No, and tell Claude what to do differently (esc)"])
    }

    func testCursorOnAnotherOptionAndHintsBelow() {
        let menu = parse([
            "Which database should I use?",
            "",
            "  1. SQLite",
            "     Small, one file",
            "❯ 2. Postgres",
            "     Needs a server",
            "  3. Type something.",
            "",
            "Enter to select · ↑/↓ to navigate · Esc to cancel",
        ])
        XCTAssertEqual(menu?.question, "Which database should I use?")
        XCTAssertEqual(labels(menu), ["SQLite Small, one file", "Postgres Needs a server", "Type something."])
        XCTAssertEqual(menu?.options.map(\.selected), [false, true, false])
    }

    func testCodexApproval() {
        let menu = parse([
            "  Would you like to run the following command?",
            "",
            "  $ git push origin main",
            "",
            "› 1. Yes, proceed (y)",
            "  2. Yes, and don't ask again for this command (a)",
            "  3. No, and tell Codex what to do differently (esc)",
            "",
            "  Press enter to confirm or esc to cancel",
            "",
        ])
        XCTAssertEqual(menu?.question, "Would you like to run the following command?")
        XCTAssertEqual(labels(menu), ["Yes, proceed (y)", "Yes, and don't ask again for this command (a)",
                                      "No, and tell Codex what to do differently (esc)"])
        XCTAssertEqual(menu?.options.first?.selected, true)
    }

    func testAsciiCursorAndParenthesisNumbers() {
        let menu = parse(["Continue?", "> 1) Yes", "  2) No"])
        XCTAssertEqual(labels(menu), ["Yes", "No"])
    }

    func testANumberedListInTheOutputIsNotAMenu() {
        // No cursor on any item.
        XCTAssertNil(parse([
            "Here is the plan:",
            "  1. Add the model",
            "  2. Write the tests",
            "  3. Wire the UI",
            "",
            "────────────────────────",
            "> ",
            "────────────────────────",
            "  ? for shortcuts",
        ]))
    }

    func testAMenuFarFromTheBottomIsIgnored() {
        var lines = ["Do you want to proceed?", "❯ 1. Yes", "  2. No"]
        lines += (1...8).map { "output line \($0)" }
        XCTAssertNil(parse(lines))
        // A status line and a hint below it are fine.
        XCTAssertNotNil(parse(["Do you want to proceed?", "❯ 1. Yes", "  2. No", "", "Esc to cancel", "main · ctx 40%"]))
    }

    func testNumbersMustCountUpFromOne() {
        XCTAssertNil(parse(["❯ 2. Yes", "  3. No"]))
        XCTAssertNil(parse(["❯ 1. Yes", "  3. No"]))
        XCTAssertNil(parse(["❯ 1. Yes"]))
    }

    func testExactlyOneCursor() {
        XCTAssertNil(parse(["❯ 1. Yes", "❯ 2. No"]))
    }

    func testTheInputLineIsNotAnOption() {
        // The user typed "1. fix it" into Claude Code's input under an ordinary list.
        XCTAssertNil(parse(["  1. one", "  2. two", "", "❯ 1. fix it"]))
    }

    func testUnrelatedTextBetweenOptionsBreaksTheMenu() {
        XCTAssertNil(parse(["❯ 1. Yes", "something else", "  2. No"]))
        XCTAssertNil(parse(["❯ 1. Yes", "", "", "  2. No"]))
        XCTAssertNil(parse(["❯ 1. Yes", "──────", "  2. No"]))
    }

    func testNumbersInOneColumn() {
        XCTAssertNil(parse(["❯ 1. Yes", "          2. No"]))
    }

    func testNoQuestionAboveABorder() {
        let menu = parse(["╭────╮", "│ ❯ 1. Yes │", "│   2. No  │", "╰────╯"])
        XCTAssertNil(menu?.question)
        XCTAssertEqual(labels(menu), ["Yes", "No"])
    }

    func testWideCharactersInTheLabel() {
        let menu = parse(["続けますか？", "❯ 1. はい", "  2. いいえ、別の方法で"])
        XCTAssertEqual(menu?.question, "続けますか？")
        XCTAssertEqual(labels(menu), ["はい", "いいえ、別の方法で"])
    }
}
