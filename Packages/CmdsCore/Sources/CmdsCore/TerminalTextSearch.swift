import Foundation

/// How the terminal find bar matches (#173). The default (neither) is what libghostty's own search does; the app
/// searches the rows itself (`TerminalTextSearch`) only for Match Case or Regular Expression.
public struct TerminalSearchOptions: Equatable, Sendable {
    public var caseSensitive: Bool
    public var regex: Bool

    public init(caseSensitive: Bool = false, regex: Bool = false) {
        self.caseSensitive = caseSensitive
        self.regex = regex
    }

    /// libghostty's search covers it: plain text, ASCII case-insensitive.
    public var isPlain: Bool { !caseSensitive && !regex }
}

/// One hit: `row` counts screen rows from the top of the history (the rows `TerminalTextSearch.matches` was given,
/// offset by its `firstRow`), `column` and `width` count cells (a wide character takes two, `TerminalCells`).
public struct TerminalSearchMatch: Equatable, Sendable {
    public var row: Int
    public var column: Int
    public var width: Int

    public init(row: Int, column: Int, width: Int) {
        self.row = row
        self.column = column
        self.width = width
    }
}

/// The find bar's own search over terminal rows (one string per displayed row, soft wraps not joined, as
/// `TerminalSurface.screenRows` reads them), for what libghostty's search cannot do: Match Case and regular
/// expressions. A hit that wraps onto the next row is not found.
public enum TerminalTextSearch {
    public enum QueryError: Error, Equatable {
        case invalidRegex(String)
    }

    /// Hits in reading order (top row first, left to right). Empty for an empty query; zero-length regex matches are
    /// skipped. At most `limit` hits. Checks `Task.isCancelled` now and then and returns what it has so far.
    public static func matches(_ query: String, in rows: [String], firstRow: Int = 0,
                               options: TerminalSearchOptions, limit: Int = 10_000) throws -> [TerminalSearchMatch] {
        guard !query.isEmpty, limit > 0 else { return [] }
        let regex: NSRegularExpression?
        if options.regex {
            do {
                regex = try NSRegularExpression(pattern: query,
                                                options: options.caseSensitive ? [] : [.caseInsensitive])
            } catch {
                throw QueryError.invalidRegex(query)
            }
        } else {
            regex = nil
        }
        var hits: [TerminalSearchMatch] = []
        for (index, row) in rows.enumerated() {
            if index % 512 == 0, Task.isCancelled { break }
            let ranges = regex.map { ranges(of: $0, in: row) } ?? ranges(of: query, in: row, caseSensitive: options.caseSensitive)
            for range in ranges {
                let column = TerminalCells.width(of: String(row[row.startIndex..<range.lowerBound]))
                hits.append(TerminalSearchMatch(row: firstRow + index, column: column,
                                                width: TerminalCells.width(of: String(row[range]))))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    /// Non-overlapping occurrences of `query` in `row`.
    static func ranges(of query: String, in row: String, caseSensitive: Bool) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var start = row.startIndex
        let options: String.CompareOptions = caseSensitive ? [.literal] : [.caseInsensitive]
        while start < row.endIndex, let range = row.range(of: query, options: options, range: start..<row.endIndex) {
            result.append(range)
            start = range.upperBound
        }
        return result
    }

    static func ranges(of regex: NSRegularExpression, in row: String) -> [Range<String.Index>] {
        regex.matches(in: row, range: NSRange(row.startIndex..., in: row)).compactMap { match in
            guard match.range.length > 0 else { return nil }
            return Range(match.range, in: row)
        }
    }

    /// The hit to select after the hits changed: the one at or above `row` nearest to it (the find bar starts at the
    /// bottom and goes up, as libghostty's search does), else the bottom one. nil when there are none.
    public static func nearestIndex(in hits: [TerminalSearchMatch], atOrAbove row: Int?) -> Int? {
        guard !hits.isEmpty else { return nil }
        guard let row else { return hits.count - 1 }
        return hits.lastIndex { $0.row <= row } ?? hits.count - 1
    }
}
