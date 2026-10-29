import Foundation

/// Small Markdown → HTML renderer for preview panes (GitHub-flavoured subset): ATX/setext headings, paragraphs,
/// emphasis, strikethrough, inline code, fenced and indented code blocks, block quotes, nested ordered/unordered
/// and task lists, tables, rules, links, images, autolinks. Raw HTML in the source is shown as text (escaped),
/// and link targets with schemes other than http(s)/mailto/file are dropped, so a document cannot inject markup
/// or script (the web view also runs with JavaScript off).
public enum MarkdownHTML {
    /// A complete HTML page (with `PreviewHTML.css`).
    public static func page(_ markdown: String, title: String) -> String {
        PreviewHTML.page(title: title, bodyClass: "markdown", body: render(markdown))
    }

    /// The HTML body fragment for `markdown`.
    public static func render(_ markdown: String) -> String {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map { expandTabs(String($0)) }
        var parser = BlockParser()
        return parser.blocks(lines, tight: false)
    }

    private static func expandTabs(_ line: String) -> String {
        guard line.contains("\t") else { return line }
        var result = ""
        var column = 0
        for character in line {
            if character == "\t" {
                let spaces = 4 - column % 4
                result += String(repeating: " ", count: spaces)
                column += spaces
            } else {
                result.append(character)
                column += 1
            }
        }
        return result
    }
}

// MARK: - Blocks

private struct BlockParser {
    var depth = 0

    mutating func blocks(_ lines: [String], tight: Bool) -> String {
        depth += 1
        defer { depth -= 1 }
        guard depth < 40 else { return "<p>" + Inline.render(lines.joined(separator: "\n")) + "</p>\n" }
        var html = ""
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if isBlank(line) {
                i += 1
                continue
            }
            if let fence = Self.fenceOpening(line) {
                var code: [String] = []
                i += 1
                while i < lines.count, !Self.closesFence(lines[i], fence: fence) {
                    code.append(Self.strip(lines[i], upTo: fence.indent))
                    i += 1
                }
                i += 1
                let info = fence.info.split(separator: " ").first.map(String.init) ?? ""
                let langClass = info.isEmpty ? "" : " class=\"language-\(PreviewHTML.escape(info))\""
                html += "<pre><code\(langClass)>" + PreviewHTML.escape(code.joined(separator: "\n")) + "\n</code></pre>\n"
                continue
            }
            if let (level, text) = Self.atxHeading(line) {
                html += heading(level, text)
                i += 1
                continue
            }
            if Self.isRule(line) {
                html += "<hr>\n"
                i += 1
                continue
            }
            if Self.quoteContent(line) != nil {
                var inner: [String] = []
                while i < lines.count {
                    if let content = Self.quoteContent(lines[i]) {
                        inner.append(content)
                    } else if !isBlank(lines[i]), let last = inner.last, !isBlank(last), !startsBlock(lines[i]) {
                        inner.append(lines[i]) // lazy continuation
                    } else {
                        break
                    }
                    i += 1
                }
                html += "<blockquote>\n" + blocks(inner, tight: false) + "</blockquote>\n"
                continue
            }
            if Self.listMarker(line) != nil {
                html += list(lines, &i)
                continue
            }
            if i + 1 < lines.count, line.contains("|"), let aligns = Self.tableSeparator(lines[i + 1]) {
                html += table(lines, &i, aligns: aligns)
                continue
            }
            if Self.indent(of: line) >= 4 {
                var code: [String] = []
                while i < lines.count, isBlank(lines[i]) || Self.indent(of: lines[i]) >= 4 {
                    code.append(Self.strip(lines[i], upTo: 4))
                    i += 1
                }
                while let last = code.last, isBlank(last) { code.removeLast() }
                html += "<pre><code>" + PreviewHTML.escape(code.joined(separator: "\n")) + "\n</code></pre>\n"
                continue
            }
            // Paragraph (or setext heading).
            var paragraph: [String] = [line]
            i += 1
            var setext: Int?
            while i < lines.count, !isBlank(lines[i]) {
                let next = lines[i]
                let trimmed = next.trimmingCharacters(in: .whitespaces)
                if Self.indent(of: next) < 4, !trimmed.isEmpty, trimmed.allSatisfy({ $0 == "=" }) {
                    setext = 1
                    i += 1
                    break
                }
                if Self.indent(of: next) < 4, trimmed.count >= 2, trimmed.allSatisfy({ $0 == "-" }) {
                    setext = 2
                    i += 1
                    break
                }
                if startsBlock(next) { break }
                paragraph.append(next)
                i += 1
            }
            if let setext {
                html += heading(setext, paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " "))
            } else {
                let text = Self.joinParagraph(paragraph)
                html += tight ? text + "\n" : "<p>" + text + "</p>\n"
            }
        }
        return html
    }

    private func heading(_ level: Int, _ text: String) -> String {
        let id = Self.slug(text)
        return "<h\(level) id=\"\(PreviewHTML.escape(id))\">" + Inline.render(text) + "</h\(level)>\n"
    }

    private func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " } }

    /// Lines that end a paragraph without a blank line.
    private func startsBlock(_ line: String) -> Bool {
        Self.fenceOpening(line) != nil || Self.atxHeading(line) != nil || Self.isRule(line)
            || Self.quoteContent(line) != nil || Self.listMarker(line).map { !$0.empty } == true
    }

    // MARK: Lists

    private mutating func list(_ lines: [String], _ i: inout Int) -> String {
        guard let first = Self.listMarker(lines[i]) else { return "" }
        var items: [[String]] = []
        var loose = false
        while i < lines.count, let marker = Self.listMarker(lines[i]), marker.indent < first.contentIndent,
              marker.ordered == first.ordered, marker.delimiter == first.delimiter {
            var item: [String] = [marker.content]
            i += 1
            var sawBlank = false
            while i < lines.count {
                let line = lines[i]
                if isBlank(line) {
                    sawBlank = true
                    item.append("")
                    i += 1
                    continue
                }
                let indent = Self.indent(of: line)
                if indent >= marker.contentIndent {
                    if sawBlank, item.count > 1 { loose = true }
                    sawBlank = false
                    item.append(Self.strip(line, upTo: marker.contentIndent))
                    i += 1
                    continue
                }
                if !sawBlank, Self.listMarker(line) == nil, !startsBlock(line) {
                    item.append(line.trimmingCharacters(in: .whitespaces)) // lazy continuation
                    i += 1
                    continue
                }
                break
            }
            // Trailing blank lines belong between items: they make the list loose only if another item follows.
            var trailing = 0
            while let last = item.last, isBlank(last) {
                item.removeLast()
                trailing += 1
            }
            if trailing > 0, i < lines.count, let next = Self.listMarker(lines[i]), next.indent < first.contentIndent,
               next.ordered == first.ordered {
                loose = true
            }
            items.append(item)
        }
        let start = first.ordered && first.number != 1 ? " start=\"\(first.number)\"" : ""
        var html = first.ordered ? "<ol\(start)>\n" : "<ul>\n"
        for item in items {
            var content = item
            var checkbox = ""
            if let head = content.first, let (checked, rest) = Self.taskMarker(head) {
                checkbox = "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> "
                content[0] = rest
            }
            let body = blocks(content, tight: !loose)
            let trimmed = body.hasSuffix("\n") ? String(body.dropLast()) : body
            html += "<li\(checkbox.isEmpty ? "" : " class=\"task\"")>" + checkbox + trimmed + "</li>\n"
        }
        html += first.ordered ? "</ol>\n" : "</ul>\n"
        return html
    }

    struct ListMarker {
        var indent: Int
        var contentIndent: Int
        var ordered: Bool
        var delimiter: Character
        var number: Int
        var content: String
        var empty: Bool
    }

    static func listMarker(_ line: String) -> ListMarker? {
        let indent = indent(of: line)
        guard indent < 4 + 12 else { return nil }
        let rest = Array(line.dropFirst(indent))
        guard !rest.isEmpty else { return nil }
        var markerLength: Int
        var ordered = false
        var delimiter: Character
        var number = 1
        if "-*+".contains(rest[0]) {
            markerLength = 1
            delimiter = rest[0]
        } else {
            var digits = 0
            while digits < rest.count, digits < 9, rest[digits].isASCII, rest[digits].isNumber { digits += 1 }
            guard digits > 0, digits < rest.count, rest[digits] == "." || rest[digits] == ")" else { return nil }
            ordered = true
            delimiter = rest[digits]
            number = Int(String(rest[0..<digits])) ?? 1
            markerLength = digits + 1
        }
        if markerLength == rest.count {
            return ListMarker(indent: indent, contentIndent: indent + markerLength + 1, ordered: ordered,
                              delimiter: delimiter, number: number, content: "", empty: true)
        }
        guard rest[markerLength] == " " else { return nil }
        var spaces = 0
        while markerLength + spaces < rest.count, rest[markerLength + spaces] == " " { spaces += 1 }
        if spaces > 4 { spaces = 1 } // indented code inside the item
        let content = String(rest.dropFirst(markerLength + spaces))
        return ListMarker(indent: indent, contentIndent: indent + markerLength + spaces, ordered: ordered,
                          delimiter: delimiter, number: number, content: content, empty: content.isEmpty)
    }

    static func taskMarker(_ line: String) -> (Bool, String)? {
        for (prefix, checked) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where line.hasPrefix(prefix) {
            return (checked, String(line.dropFirst(prefix.count)))
        }
        return nil
    }

    // MARK: Tables

    private func table(_ lines: [String], _ i: inout Int, aligns: [String?]) -> String {
        let header = Self.cells(lines[i])
        i += 2
        var html = "<table>\n<thead>\n<tr>"
        for (index, cell) in header.enumerated() {
            html += "<th\(Self.alignAttribute(aligns, index))>" + Inline.render(cell) + "</th>"
        }
        html += "</tr>\n</thead>\n<tbody>\n"
        while i < lines.count, !isBlank(lines[i]), lines[i].contains("|"), !startsBlock(lines[i]) {
            let row = Self.cells(lines[i])
            html += "<tr>"
            for index in 0..<header.count {
                html += "<td\(Self.alignAttribute(aligns, index))>" + Inline.render(row[safe: index] ?? "") + "</td>"
            }
            html += "</tr>\n"
            i += 1
        }
        return html + "</tbody>\n</table>\n"
    }

    static func alignAttribute(_ aligns: [String?], _ index: Int) -> String {
        guard index < aligns.count, let align = aligns[index] else { return "" }
        return " style=\"text-align:\(align)\""
    }

    static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for character in text {
            if escaped {
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                inCode.toggle()
                current.append(character)
            } else if character == "|", !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    static func tableSeparator(_ line: String) -> [String?]? {
        guard line.contains("-") else { return nil }
        let cells = cells(line)
        var aligns: [String?] = []
        for cell in cells {
            guard !cell.isEmpty, cell.allSatisfy({ "-:".contains($0) }), cell.contains("-") else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): aligns.append("center")
            case (false, true): aligns.append("right")
            case (true, false): aligns.append("left")
            default: aligns.append(nil)
            }
        }
        return aligns
    }

    // MARK: Line helpers

    static func indent(of line: String) -> Int {
        var count = 0
        for character in line {
            guard character == " " else { break }
            count += 1
        }
        return count
    }

    static func strip(_ line: String, upTo spaces: Int) -> String {
        String(line.dropFirst(min(spaces, indent(of: line))))
    }

    struct Fence {
        var marker: Character
        var length: Int
        var indent: Int
        var info: String
    }

    static func fenceOpening(_ line: String) -> Fence? {
        let indent = indent(of: line)
        guard indent < 4 else { return nil }
        let rest = line.dropFirst(indent)
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let length = rest.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        let info = rest.dropFirst(length).trimmingCharacters(in: .whitespaces)
        if marker == "`", info.contains("`") { return nil }
        return Fence(marker: marker, length: length, indent: indent, info: info)
    }

    static func closesFence(_ line: String, fence: Fence) -> Bool {
        let indent = indent(of: line)
        guard indent < 4 else { return false }
        let rest = line.dropFirst(indent)
        let length = rest.prefix { $0 == fence.marker }.count
        return length >= fence.length && rest.dropFirst(length).allSatisfy { $0 == " " }
    }

    static func atxHeading(_ line: String) -> (Int, String)? {
        let indent = indent(of: line)
        guard indent < 4 else { return nil }
        let rest = line.dropFirst(indent)
        let level = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let after = rest.dropFirst(level)
        guard after.isEmpty || after.first == " " else { return nil }
        var text = after.trimmingCharacters(in: .whitespaces)
        // Closing sequence: " ###".
        if let range = text.range(of: #"(^|\s)#+$"#, options: .regularExpression) {
            text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return (level, text)
    }

    static func isRule(_ line: String) -> Bool {
        guard indent(of: line) < 4 else { return false }
        let compact = line.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func quoteContent(_ line: String) -> String? {
        let indent = indent(of: line)
        guard indent < 4 else { return nil }
        let rest = line.dropFirst(indent)
        guard rest.first == ">" else { return nil }
        let after = rest.dropFirst()
        return String(after.first == " " ? after.dropFirst() : after)
    }

    /// Joins paragraph lines; two trailing spaces or a trailing backslash make a hard break.
    static func joinParagraph(_ lines: [String]) -> String {
        var parts: [String] = []
        for (index, raw) in lines.enumerated() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            let last = index == lines.count - 1
            var hardBreak = false
            if !last, raw.hasSuffix("  ") { hardBreak = true }
            if !last, line.hasSuffix("\\") {
                hardBreak = true
                line.removeLast()
            }
            parts.append(Inline.render(line) + (hardBreak ? "<br>" : ""))
        }
        return parts.joined(separator: "\n")
    }

    static func slug(_ text: String) -> String {
        let plain = text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
        return plain.replacingOccurrences(of: " ", with: "-")
    }
}

// MARK: - Inline

enum Inline {
    static func render(_ text: String) -> String {
        var parser = InlineParser(Array(text))
        return parser.run(until: nil)
    }
}

private struct InlineParser {
    let chars: [Character]
    var i = 0
    var depth = 0
    /// The last `run(until:)` stopped at its closer (not at the end of the text).
    var didClose = false

    init(_ chars: [Character]) { self.chars = chars }

    static let punctuation: Set<Character> = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

    /// Renders until the delimiter string `closer` (consumed) or the end.
    mutating func run(until closer: String?) -> String {
        var out = ""
        didClose = false
        while i < chars.count {
            if let closer, matches(closer, at: i), canClose(closer, at: i) {
                i += closer.count
                didClose = true
                return out
            }
            let c = chars[i]
            switch c {
            case "\\":
                if i + 1 < chars.count, Self.punctuation.contains(chars[i + 1]) {
                    out += PreviewHTML.escape(String(chars[i + 1]))
                    i += 2
                } else {
                    out += "\\"
                    i += 1
                }
            case "`":
                out += codeSpan()
            case "!" where i + 1 < chars.count && chars[i + 1] == "[":
                if let html = linkOrImage(image: true) { out += html } else {
                    out += "!"
                    i += 1
                }
            case "[":
                if let html = linkOrImage(image: false) { out += html } else {
                    out += "["
                    i += 1
                }
            case "<":
                if let html = autolink() { out += html } else {
                    out += "&lt;"
                    i += 1
                }
            case "*", "_", "~":
                out += emphasis()
            case "h" where matches("http://", at: i) || matches("https://", at: i):
                if let html = bareURL() { out += html } else {
                    out += "h"
                    i += 1
                }
            default:
                out += PreviewHTML.escape(String(c))
                i += 1
            }
        }
        return out
    }

    func matches(_ string: String, at index: Int) -> Bool {
        let s = Array(string)
        guard index + s.count <= chars.count else { return false }
        return Array(chars[index ..< index + s.count]) == s
    }

    /// A closing delimiter must follow non-space text and not be part of a longer run.
    func canClose(_ closer: String, at index: Int) -> Bool {
        guard index > 0, !chars[index - 1].isWhitespace else { return false }
        let end = index + closer.count
        if let first = closer.first, end < chars.count, chars[end] == first, closer.count < 3 { return false }
        if closer == "_", end < chars.count, chars[end].isLetter || chars[end].isNumber { return false }
        return true
    }

    mutating func codeSpan() -> String {
        var run = 0
        while i + run < chars.count, chars[i + run] == "`" { run += 1 }
        let ticks = String(repeating: "`", count: run)
        var j = i + run
        while j < chars.count {
            if chars[j] == "`" {
                var closing = 0
                while j + closing < chars.count, chars[j + closing] == "`" { closing += 1 }
                if closing == run {
                    var code = String(chars[(i + run) ..< j]).replacingOccurrences(of: "\n", with: " ")
                    if code.count >= 2, code.hasPrefix(" "), code.hasSuffix(" "), code.contains(where: { $0 != " " }) {
                        code = String(code.dropFirst().dropLast())
                    }
                    i = j + closing
                    return "<code>" + PreviewHTML.escape(code) + "</code>"
                }
                j += closing
            } else {
                j += 1
            }
        }
        i += run
        return PreviewHTML.escape(ticks)
    }

    mutating func emphasis() -> String {
        let c = chars[i]
        var run = 0
        while i + run < chars.count, chars[i + run] == c { run += 1 }
        let next = i + run < chars.count ? chars[i + run] : " "
        let previous = i > 0 ? chars[i - 1] : " "
        let opens = !next.isWhitespace && !(c == "_" && (previous.isLetter || previous.isNumber))
        guard depth < 20, opens, c != "~" || run == 2 else {
            i += run
            return PreviewHTML.escape(String(repeating: c, count: run))
        }
        let length = c == "~" ? 2 : min(run, 3)
        let delimiter = String(repeating: c, count: length)
        // Try to find a closer; parse the inner text recursively from the current position.
        let saved = i
        i += length
        var inner = InlineParser(chars)
        inner.i = i
        inner.depth = depth + 1
        let html = inner.run(until: delimiter)
        if inner.didClose {
            i = inner.i
            switch (c, length) {
            case ("~", _): return "<del>" + html + "</del>"
            case (_, 1): return "<em>" + html + "</em>"
            case (_, 2): return "<strong>" + html + "</strong>"
            default: return "<strong><em>" + html + "</em></strong>"
            }
        }
        i = saved + run
        return PreviewHTML.escape(String(repeating: c, count: run))
    }

    mutating func linkOrImage(image: Bool) -> String? {
        let open = image ? i + 1 : i
        guard let close = matchingBracket(from: open) else { return nil }
        let label = String(chars[(open + 1) ..< close])
        guard close + 1 < chars.count, chars[close + 1] == "(" else { return nil }
        guard let (destination, title, end) = destination(from: close + 2) else { return nil }
        i = end
        let href = PreviewHTML.safeURL(destination)
        let titleAttribute = title.map { " title=\"\(PreviewHTML.escape($0))\"" } ?? ""
        if image {
            guard let href else { return PreviewHTML.escape(label) }
            return "<img src=\"\(PreviewHTML.escape(href))\" alt=\"\(PreviewHTML.escape(label))\"\(titleAttribute)>"
        }
        var inner = InlineParser(Array(label))
        inner.depth = depth + 1
        let text = inner.run(until: nil)
        guard let href else { return text }
        return "<a href=\"\(PreviewHTML.escape(href))\"\(titleAttribute)>" + text + "</a>"
    }

    func matchingBracket(from open: Int) -> Int? {
        var level = 0
        var j = open
        while j < chars.count {
            switch chars[j] {
            case "\\": j += 1
            case "[": level += 1
            case "]":
                level -= 1
                if level == 0 { return j }
            case "`":
                // Skip code spans inside labels.
                var k = j + 1
                while k < chars.count, chars[k] != "`" { k += 1 }
                if k < chars.count { j = k }
            default: break
            }
            j += 1
        }
        return nil
    }

    /// `(dest "title")` starting after "(": returns destination, title, index after ")".
    func destination(from start: Int) -> (String, String?, Int)? {
        var j = start
        while j < chars.count, chars[j] == " " { j += 1 }
        var destination = ""
        if j < chars.count, chars[j] == "<" {
            j += 1
            while j < chars.count, chars[j] != ">" {
                destination.append(chars[j])
                j += 1
            }
            guard j < chars.count else { return nil }
            j += 1
        } else {
            var parens = 0
            while j < chars.count, !chars[j].isWhitespace {
                if chars[j] == "(" { parens += 1 }
                if chars[j] == ")" {
                    if parens == 0 { break }
                    parens -= 1
                }
                destination.append(chars[j])
                j += 1
            }
        }
        while j < chars.count, chars[j] == " " { j += 1 }
        var title: String?
        if j < chars.count, let quote = Optional(chars[j]), quote == "\"" || quote == "'" {
            var k = j + 1
            var text = ""
            while k < chars.count, chars[k] != quote {
                text.append(chars[k])
                k += 1
            }
            guard k < chars.count else { return nil }
            title = text
            j = k + 1
            while j < chars.count, chars[j] == " " { j += 1 }
        }
        guard j < chars.count, chars[j] == ")" else { return nil }
        return (destination, title, j + 1)
    }

    mutating func autolink() -> String? {
        var j = i + 1
        var text = ""
        while j < chars.count, chars[j] != ">", chars[j] != "<", !chars[j].isWhitespace {
            text.append(chars[j])
            j += 1
        }
        guard j < chars.count, chars[j] == ">", !text.isEmpty else { return nil }
        let href: String
        if text.range(of: #"^[A-Za-z][A-Za-z0-9+.-]{1,31}:"#, options: .regularExpression) != nil {
            href = text
        } else if text.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil {
            href = "mailto:" + text
        } else {
            return nil
        }
        i = j + 1
        guard let safe = PreviewHTML.safeURL(href) else { return PreviewHTML.escape(text) }
        return "<a href=\"\(PreviewHTML.escape(safe))\">" + PreviewHTML.escape(text) + "</a>"
    }

    mutating func bareURL() -> String? {
        if i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber { return nil }
        var j = i
        var text = ""
        while j < chars.count, !chars[j].isWhitespace, chars[j] != "<" {
            text.append(chars[j])
            j += 1
        }
        while let last = text.last, ".,;:!?)'\"*_".contains(last) {
            if last == ")", text.filter({ $0 == "(" }).count >= text.filter({ $0 == ")" }).count { break }
            text.removeLast()
            j -= 1
        }
        guard text.count > "https://".count else { return nil }
        i = j
        return "<a href=\"\(PreviewHTML.escape(text))\">" + PreviewHTML.escape(text) + "</a>"
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
