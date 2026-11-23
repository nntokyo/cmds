import Foundation

/// Edit › Find › Find in All Terminals (#174 G12): the lines of every terminal's scrollback that contain the text, for
/// the panel that lists them. User-initiated only: no API or MCP reads other panes through this.
public enum AllTerminalsSearch {
    /// Lines read per terminal when the panel opens (the newest).
    public static let maxLinesPerTerminal = 5_000
    /// Hits listed at most (the newest of each terminal first, terminals in order).
    public static let maxHits = 300
    /// Characters of a line shown; a longer one is cut around the match.
    public static let maxLineLength = 160

    public struct Hit: Equatable, Sendable {
        /// The source's key (a pane id).
        public var key: String
        /// The line as shown: leading spaces trimmed, cut around the match (`…` where cut).
        public var line: String
        /// The matched characters in `line`, as `Character` offsets.
        public var positions: [Int]
        /// Lines below it in its terminal (0: the last line).
        public var fromEnd: Int

        public init(key: String, line: String, positions: [Int], fromEnd: Int) {
            self.key = key
            self.line = line
            self.positions = positions
            self.fromEnd = fromEnd
        }
    }

    /// The lines of `sources` (key, text) that contain `query` (case and diacritics ignored), newest first within each
    /// source, at most `limit`. An empty or blank query finds nothing.
    public static func search(_ sources: [(key: String, text: String)], query: String, limit: Int = maxHits) -> [Hit] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty, limit > 0 else { return [] }
        var hits: [Hit] = []
        for source in sources {
            let lines = source.text.components(separatedBy: "\n")
            for (offset, raw) in lines.reversed().enumerated() {
                guard let range = raw.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
                hits.append(hit(key: source.key, raw: raw, range: range, fromEnd: offset))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    private static func hit(key: String, raw: String, range: Range<String.Index>, fromEnd: Int) -> Hit {
        let characters = Array(raw)
        let start = raw.distance(from: raw.startIndex, to: range.lowerBound)
        let length = raw.distance(from: range.lowerBound, to: range.upperBound)
        // Leading spaces go; a long line keeps some text before the match and is cut after.
        let indent = characters.prefix { $0 == " " || $0 == "\t" }.count
        var from = min(indent, start)
        if start - from > 40 { from = start - 40 }
        let to = min(characters.count, from + maxLineLength)
        var line = String(characters[from..<to])
        var shift = from
        if from > indent {
            line = "…" + line
            shift -= 1
        }
        if to < characters.count { line += "…" }
        let positions = (start..<min(start + length, to)).map { $0 - shift }
        return Hit(key: key, line: line, positions: positions, fromEnd: fromEnd)
    }
}
