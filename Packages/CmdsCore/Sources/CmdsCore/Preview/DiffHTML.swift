import Foundation

/// Unified diff (`git diff`, `diff -u`, `.patch`) → coloured HTML: one box per file with its name and +/- counts,
/// old/new line numbers, added lines green, removed red, hunk headers blue. Lines outside hunks (commit messages,
/// `index …`) are shown dimmed.
public enum DiffHTML {
    public static func page(_ diff: String, title: String) -> String {
        PreviewHTML.page(title: title, bodyClass: "diff", body: render(diff))
    }

    public static func render(_ diff: String) -> String {
        let lines = diff.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        var files: [FileSection] = []
        var current = FileSection()
        var oldLine = 0
        var newLine = 0
        // Lines left in the current hunk (from its header); file headers are only recognised outside hunks.
        var oldLeft = 0
        var newLeft = 0

        func startFile() {
            if !current.rows.isEmpty || current.name != nil { files.append(current) }
            current = FileSection()
        }

        var index = 0
        while index < lines.count {
            let line = String(lines[index])
            index += 1
            if oldLeft > 0 || newLeft > 0 {
                if line.hasPrefix("+") {
                    current.rows.append(.add(newLine, String(line.dropFirst())))
                    current.added += 1
                    newLine += 1
                    newLeft -= 1
                    continue
                }
                if line.hasPrefix("-") {
                    current.rows.append(.del(oldLine, String(line.dropFirst())))
                    current.removed += 1
                    oldLine += 1
                    oldLeft -= 1
                    continue
                }
                if line.hasPrefix(" ") || line.isEmpty {
                    current.rows.append(.context(oldLine, newLine, String(line.dropFirst())))
                    oldLine += 1
                    newLine += 1
                    oldLeft -= 1
                    newLeft -= 1
                    continue
                }
                if !line.hasPrefix("\\") {
                    // Malformed hunk: treat the rest as headers.
                    oldLeft = 0
                    newLeft = 0
                }
            }
            if line.hasPrefix("\\") {
                current.rows.append(.meta(line)) // "\ No newline at end of file"
                continue
            }
            if line.hasPrefix("diff ") {
                startFile()
                current.name = Self.name(fromDiffGit: line)
                current.rows.append(.meta(line))
                continue
            }
            if line.hasPrefix("--- "), index < lines.count, lines[index].hasPrefix("+++ ") {
                if current.rows.contains(where: \.isHunk) { startFile() }
                let oldName = Self.path(String(line.dropFirst(4)))
                let newName = Self.path(String(lines[index].dropFirst(4)))
                current.name = newName == "/dev/null" ? oldName : newName
                current.rows.append(.meta(line))
                current.rows.append(.meta(String(lines[index])))
                index += 1
                continue
            }
            if line.hasPrefix("@@"), let hunk = Self.hunkHeader(line) {
                (oldLine, oldLeft, newLine, newLeft) = hunk
                current.rows.append(.hunk(line))
                continue
            }
            if line.isEmpty, index == lines.count { continue } // final newline
            current.rows.append(.meta(line))
        }
        startFile()
        if files.isEmpty { return "<p style=\"padding:12px;color:var(--muted)\">Empty diff</p>" }
        return files.map(\.html).joined()
    }

    private struct FileSection {
        var name: String?
        var rows: [Row] = []
        var added = 0
        var removed = 0

        var html: String {
            var out = "<div class=\"file\">"
            if let name {
                out += "<div class=\"file-name\">\(PreviewHTML.escape(name))"
                out += "<span class=\"stat\"><span class=\"a\">+\(added)</span> <span class=\"d\">−\(removed)</span></span></div>"
            }
            out += "<table class=\"diff\">"
            for row in rows { out += row.html }
            return out + "</table></div>\n"
        }
    }

    private enum Row {
        case meta(String)
        case hunk(String)
        case add(Int, String)
        case del(Int, String)
        case context(Int, Int, String)

        var isHunk: Bool {
            if case .hunk = self { return true }
            return false
        }

        var html: String {
            func cell(_ n: Int?) -> String { "<td class=\"ln\">\(n.map(String.init) ?? "")</td>" }
            switch self {
            case .meta(let text):
                return "<tr class=\"meta\"><td class=\"ln\"></td><td class=\"ln\"></td><td>\(PreviewHTML.escape(text))</td></tr>"
            case .hunk(let text):
                return "<tr class=\"hunk\"><td class=\"ln\"></td><td class=\"ln\"></td><td>\(PreviewHTML.escape(text))</td></tr>"
            case .add(let n, let text):
                return "<tr class=\"add\">\(cell(nil))\(cell(n))<td class=\"code\">\(PreviewHTML.escape(text))</td></tr>"
            case .del(let n, let text):
                return "<tr class=\"del\">\(cell(n))\(cell(nil))<td class=\"code\">\(PreviewHTML.escape(text))</td></tr>"
            case .context(let old, let new, let text):
                return "<tr class=\"ctx\">\(cell(old))\(cell(new))<td class=\"code\">\(PreviewHTML.escape(text))</td></tr>"
            }
        }
    }

    /// `@@ -a,b +c,d @@` → (old start, old count, new start, new count); counts default to 1.
    static func hunkHeader(_ line: String) -> (Int, Int, Int, Int)? {
        let pattern = #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        func group(_ i: Int, default value: Int) -> Int {
            guard let range = Range(match.range(at: i), in: line) else { return value }
            return Int(line[range]) ?? value
        }
        return (group(1, default: 0), group(2, default: 1), group(3, default: 0), group(4, default: 1))
    }

    static func name(fromDiffGit line: String) -> String? {
        // "diff --git a/x b/x": take the b/ side.
        guard let range = line.range(of: " b/", options: .backwards) else { return nil }
        return String(line[range.upperBound...])
    }

    static func path(_ raw: String) -> String {
        var path = raw
        if let tab = path.firstIndex(of: "\t") { path = String(path[..<tab]) } // "--- file\t2024-01-01 …"
        if path.hasPrefix("a/") || path.hasPrefix("b/") { path.removeFirst(2) }
        return path
    }
}
