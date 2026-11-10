import Foundation

/// A numbered choice menu that a coding agent draws at the bottom of its screen (#213): Claude Code's permission
/// prompts and questions (`❯ 1. Yes` / `  2. Yes, and don't ask again …` / `  3. No, and tell Claude …`), Codex's
/// approvals (`› 1. Yes, proceed (y)`). The menu bar's reply panel shows the options as buttons.
///
/// Conservative on purpose, so a numbered list in an agent's answer never becomes buttons:
/// - Only the bottom of the screen counts: below the last option come at most `maxTrailingLines` other non-blank lines
///   (key hints such as "Esc to cancel", a status line); blank lines and borders are not counted.
/// - The options are lines `N. label` (or `N) label`) numbered 1, 2, 3… in order, 2 to 9 of them, their numbers in one
///   column (±1 cell), and exactly one carries the selection cursor (`❯`, `›`, `>` or `▶`) before its number: an
///   agent's menu always has one, a list in its output has none.
/// - Between options only lines indented at least to the label (a wrapped label, a description, joined to the label)
///   and single blank lines may stand; anything else means no menu.
/// - The question is the nearest line above option 1 ending in "?" (up to 4 lines of text up, stopping at a border or
///   more than 2 blank lines), else the nearest line of text.
/// Box drawing around the menu (`│ … │` sides, `╭──╮` borders) is stripped first.
public struct AgentPromptOptions: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        /// What to type to pick it (1–9).
        public var number: Int
        public var label: String
        /// The agent's cursor is on it (Return picks it).
        public var selected: Bool

        public init(number: Int, label: String, selected: Bool) {
            self.number = number
            self.label = label
            self.selected = selected
        }
    }

    public var question: String?
    public var options: [Option]

    public init(question: String?, options: [Option]) {
        self.question = question
        self.options = options
    }

    /// Non-blank lines (other than borders) allowed below the last option.
    public static let maxTrailingLines = 4
    /// Lines of one option (a long wrapped label or a description), beyond which the block is not a menu.
    static let maxLinesPerOption = 6
    static let cursorMarks: Set<Character> = ["❯", "›", ">", "▶"]

    /// The menu at the bottom of `text` (a pane's visible screen, rows separated by "\n"); nil when there is none.
    public static func parse(_ text: String) -> AgentPromptOptions? {
        parse(lines: text.components(separatedBy: "\n"))
    }

    public static func parse(lines rawLines: [String]) -> AgentPromptOptions? {
        let lines = rawLines.map(unframed)
        // The last option, near the bottom.
        var trailing = 0
        var lastIndex: Int?
        for index in lines.indices.reversed() {
            let line = lines[index]
            if isBlank(line) || isBorder(line) { continue }
            if optionLine(line) != nil {
                lastIndex = index
                break
            }
            trailing += 1
            if trailing > maxTrailingLines + maxLinesPerOption { return nil }
        }
        guard let lastIndex, let last = optionLine(lines[lastIndex]), last.number >= 2 else { return nil }

        // Up to option 1: options counting down, lines that may continue the option above them, single blank lines.
        var optionIndices = [lastIndex]
        var expected = last.number - 1
        var blankRun = 0
        var linesSinceOption = 0
        var index = lastIndex - 1
        while expected >= 1 {
            guard index >= 0 else { return nil }
            let line = lines[index]
            if isBlank(line) {
                blankRun += 1
                if blankRun > 1 { return nil }
            } else if let option = optionLine(line) {
                guard option.number == expected else { return nil }
                optionIndices.insert(index, at: 0)
                expected -= 1
                blankRun = 0
                linesSinceOption = 0
            } else {
                if isBorder(line) { return nil }
                blankRun = 0
                linesSinceOption += 1
                if linesSinceOption >= maxLinesPerOption { return nil }
            }
            index -= 1
        }

        // Down from option 1: each option with its continuation lines.
        var options: [Option] = []
        var numberColumns: [Int] = []
        for (position, start) in optionIndices.enumerated() {
            guard let parsed = optionLine(lines[start]) else { return nil }
            var label = parsed.label
            let end = position + 1 < optionIndices.count ? optionIndices[position + 1] : lines.count
            var continued = 0
            for line in lines[(start + 1)..<end] {
                if isBlank(line) {
                    if position + 1 == optionIndices.count { break }  // below the last option: hints follow
                    continue
                }
                guard indentation(line) >= parsed.labelColumn, !isBorder(line) else {
                    if position + 1 == optionIndices.count { break }  // a hint below the menu
                    return nil
                }
                continued += 1
                label += " " + line.trimmingCharacters(in: .whitespaces)
            }
            if position + 1 == optionIndices.count {
                // What stands below the menu, not counting the last option's own lines.
                let below = lines[(start + 1)...].filter { !isBlank($0) && !isBorder($0) }.count - continued
                if below > maxTrailingLines { return nil }
            }
            options.append(Option(number: parsed.number, label: label, selected: parsed.selected))
            numberColumns.append(parsed.numberColumn)
        }
        guard options.count >= 2, options.count { $0.selected } == 1,
              let low = numberColumns.min(), let high = numberColumns.max(), high - low <= 1 else { return nil }

        return AgentPromptOptions(question: question(above: optionIndices[0], in: lines), options: options)
    }

    /// The nearest non-blank line above the first option, if it is text; a line ending in "?" a little higher wins
    /// (Codex shows the command between its question and the options).
    private static func question(above index: Int, in lines: [String]) -> String? {
        var texts: [String] = []
        var blanks = 0
        var i = index - 1
        while i >= 0, texts.count < 4 {
            let line = lines[i]
            i -= 1
            if isBlank(line) {
                blanks += 1
                if blanks > 2 { break }
                continue
            }
            if isBorder(line) || optionLine(line) != nil { break }
            blanks = 0
            texts.append(line.trimmingCharacters(in: .whitespaces))
        }
        return texts.first { $0.hasSuffix("?") || $0.hasSuffix("？") } ?? texts.first
    }

    // MARK: Lines

    struct OptionLine {
        var number: Int
        var label: String
        var selected: Bool
        /// Cell column of the number.
        var numberColumn: Int
        /// Cell column where the label starts (continuation lines are indented at least this far).
        var labelColumn: Int
    }

    /// `[spaces][cursor mark][spaces]N. label` or `N) label`, N 1–9.
    static func optionLine(_ line: String) -> OptionLine? {
        let characters = Array(line)
        var i = 0
        var column = 0
        func skipSpaces() {
            while i < characters.count, characters[i] == " " || characters[i] == "\u{00A0}" {
                i += 1
                column += 1
            }
        }
        skipSpaces()
        var selected = false
        if i < characters.count, cursorMarks.contains(characters[i]) {
            selected = true
            column += TerminalCells.width(of: characters[i])
            i += 1
            skipSpaces()
        }
        guard i + 2 < characters.count, let digit = characters[i].wholeNumberValue, characters[i].isASCII,
              (1...9).contains(digit), characters[i + 1] == "." || characters[i + 1] == ")",
              characters[i + 2] == " " else { return nil }
        let numberColumn = column
        i += 2
        column += 2
        skipSpaces()
        let label = String(characters[i...]).trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return OptionLine(number: digit, label: label, selected: selected, numberColumn: numberColumn, labelColumn: column)
    }

    /// Cells of leading spaces.
    static func indentation(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\u{00A0}" }.count
    }

    static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\u{00A0}" }
    }

    /// A line of box drawing (`╭────╮`, `────`), possibly with spaces.
    static func isBorder(_ line: String) -> Bool {
        var drawing = false
        for scalar in line.unicodeScalars where scalar != " " {
            guard (0x2500...0x259F).contains(scalar.value) else { return false }
            drawing = true
        }
        return drawing
    }

    private static let sides: Set<Character> = ["│", "┃", "║"]

    /// The line without a box's sides (`│ text │` → ` text`; the inner indentation stays) or trailing spaces.
    static func unframed(_ line: String) -> String {
        var text = Substring(line)
        while let last = text.last, last == " " || last == "\u{00A0}" { text = text.dropLast() }
        if let last = text.last, sides.contains(last) {
            text = text.dropLast()
            while let last = text.last, last == " " { text = text.dropLast() }
        }
        let leading = text.prefix { $0 == " " }
        let rest = text.dropFirst(leading.count)
        if let first = rest.first, sides.contains(first) { text = rest.dropFirst() }
        return String(text)
    }
}
