import Foundation

/// Whether a coding agent's input box holds text a person typed and has not sent: cmds then types nothing
/// into the pane, because a pasted prompt would join that text and Return would send both. Read off the visible
/// screen, with each row's styles where the engine gives them.
///
/// - Claude Code draws its input between the last two horizontal rules (`────`), the first row starting with its
///   prompt mark (`❯`, or `!`, `#`, `&`, `>` in its other modes); every further row of a longer text is inside too.
/// - Codex has no rules: its input is the last row near the bottom that starts with `› `.
/// - Claude Code is typed into only while that box is on screen (`State.missing`): its dialogs (the folder trust
///   question, whose choices carry no numbers) take Return as an answer.
/// - A placeholder or a suggested prompt is not typed text: both agents draw it faint or grey, and the cursor block
///   over its first character is drawn inverse. With no styles to look at, any text counts (the safe side).
public enum AgentInputBox {
    static let promptMarks: Set<Character> = ["❯", ">", "›", "!", "#", "&"]
    static let ruleCharacters: Set<Character> = ["─", "━"]
    static let minRuleLength = 10
    /// How many of the screen's last non-blank rows the Codex prompt row is looked for in.
    static let codexRows = 8

    public enum State: Equatable, Sendable {
        /// No input box on screen: the agent shows something else (a question, a dialog such as "Is this a project
        /// you trust?", a menu), or is not at its prompt.
        case missing
        case empty
        /// The box holds text a person typed.
        case typed
    }

    public static func state(rows: [String], runs: [[StyleRun]]? = nil) -> State {
        if let box = claudeBox(rows) {
            for row in box where containsTypedText(rows[row], runs: runs?[safe: row], skippingMark: row == box.lowerBound) {
                return .typed
            }
            return .empty
        }
        guard let row = codexRow(rows) else { return .missing }
        return containsTypedText(rows[row], runs: runs?[safe: row], skippingMark: true) ? .typed : .empty
    }

    public static func hasTypedText(rows: [String], runs: [[StyleRun]]? = nil) -> Bool {
        state(rows: rows, runs: runs) == .typed
    }

    /// The rows between the last two rules, when the first of them starts with a prompt mark.
    static func claudeBox(_ rows: [String]) -> Range<Int>? {
        let rules = rows.indices.filter { isRule(rows[$0]) }
        guard rules.count >= 2 else { return nil }
        let box = (rules[rules.count - 2] + 1)..<rules[rules.count - 1]
        guard !box.isEmpty, let mark = rows[box.lowerBound].first(where: { !$0.isWhitespace }),
              promptMarks.contains(mark) else { return nil }
        return box
    }

    static func isRule(_ row: String) -> Bool {
        let trimmed = row.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= minRuleLength && trimmed.allSatisfy { ruleCharacters.contains($0) }
    }

    static func codexRow(_ rows: [String]) -> Int? {
        let filled = rows.indices.filter { !rows[$0].allSatisfy(\.isWhitespace) }.suffix(codexRows)
        return filled.last { index in
            let trimmed = rows[index].drop { $0 == " " }
            return trimmed.first == "›" && (trimmed.dropFirst().first.map { $0 == " " } ?? true)
        }
    }

    /// A character that is not blank and not drawn as a placeholder (faint, grey) or under the cursor (inverse).
    static func containsTypedText(_ row: String, runs: [StyleRun]?, skippingMark: Bool) -> Bool {
        var column = 0
        var markSkipped = !skippingMark
        for character in row {
            let width = TerminalCells.width(of: character)
            defer { column += width }
            guard !character.isWhitespace else { continue }
            guard markSkipped else {
                markSkipped = true
                continue
            }
            guard let runs else { return true }
            let style = runs.first { $0.column <= column && column < $0.end }?.style
            if let style, isPlaceholder(style) { continue }
            return true
        }
        return false
    }

    static func isPlaceholder(_ style: TerminalStyle) -> Bool {
        if style.attributes.contains(.faint) || style.attributes.contains(.inverse) { return true }
        switch style.foreground {
        case .palette(let index)?: return index == 8 || (232...250).contains(index)
        case .rgb(let r, let g, let b)?:
            let high = max(r, g, b), low = min(r, g, b)
            return high - low <= 24 && high <= 200
        case nil: return false
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
