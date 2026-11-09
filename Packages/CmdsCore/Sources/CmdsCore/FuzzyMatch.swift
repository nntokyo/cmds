import Foundation

/// The command palette's matcher (#173): every query character must appear in the candidate in order (not
/// necessarily adjacent); runs of adjacent characters, word starts and an early start score higher. Words of the
/// query (split at spaces) match independently, in any order. Case, full/half width and hiragana/katakana are
/// ignored, so `わーく` finds `ワークスペース`.
public enum FuzzyMatch {
    public struct Result: Equatable, Sendable {
        /// Higher is better.
        public var score: Int
        /// Matched characters, as offsets into the candidate's `Character`s, ascending.
        public var positions: [Int]
    }

    /// A candidate prepared once (folded characters, word starts) and matched against many queries.
    public struct Candidate: Sendable {
        public let text: String
        let folded: [Character]
        let wordStart: [Bool]

        public init(_ text: String) {
            self.text = text
            let characters = Array(text)
            folded = characters.map(FuzzyMatch.fold)
            wordStart = characters.indices.map { index in
                guard index > 0 else { return true }
                let previous = characters[index - 1], current = characters[index]
                if FuzzyMatch.separators.contains(previous) { return true }
                // camelCase and a letter after a digit or symbol.
                if previous.isLowercase && current.isUppercase { return true }
                return !previous.isLetter && !previous.isNumber && (current.isLetter || current.isNumber)
            }
        }
    }

    static let separators: Set<Character> = [" ", "-", "_", "/", ".", ":", "›", ">", "(", "[", "—", "　", "・"]

    /// One `Character` folded for comparison: lowercased, half width, hiragana for katakana. Characters whose folded
    /// form is longer than one character (ß → ss) are only lowercased, so offsets stay offsets into the candidate.
    static func fold(_ character: Character) -> Character {
        var string = String(character).folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
        if let transformed = string.applyingTransform(.hiraganaToKatakana, reverse: true) { string = transformed }
        if string.count == 1, let folded = string.first { return folded }
        let lower = String(character).lowercased()
        return lower.count == 1 ? Character(lower) : character
    }

    public static func match(_ query: String, _ candidate: String) -> Result? {
        match(query, Candidate(candidate))
    }

    /// nil when some word of the query is not in the candidate. An empty query matches everything with score 0.
    public static func match(_ query: String, _ candidate: Candidate) -> Result? {
        let words = query.split(whereSeparator: { $0 == " " || $0 == "　" }).map { $0.map(fold) }
        var score = 0
        var positions = Set<Int>()
        for word in words {
            guard let result = matchWord(word, candidate) else { return nil }
            score += result.score
            positions.formUnion(result.positions)
        }
        return Result(score: score, positions: positions.sorted())
    }

    private static let matchScore = 16
    private static let adjacentBonus = 18
    private static let wordStartBonus = 12
    private static let firstCharacterBonus = 8
    private static let gapPenalty = 1
    private static let leadingGapPenalty = 1
    private static let maxLeadingGapPenalty = 12

    /// Best placement of one word: dynamic programming over (query character, candidate position).
    private static func matchWord(_ word: [Character], _ candidate: Candidate) -> Result? {
        let text = candidate.folded
        let n = word.count, m = text.count
        guard n > 0 else { return Result(score: 0, positions: []) }
        guard n <= m else { return nil }
        let none = Int.min / 2
        // best[i][j]: best score with word[0...i] placed and word[i] at text[j]; from[i][j]: where word[i-1] was.
        var best = Array(repeating: Array(repeating: none, count: m), count: n)
        var from = Array(repeating: Array(repeating: -1, count: m), count: n)
        for j in 0..<m where text[j] == word[0] {
            var score = matchScore - min(j * leadingGapPenalty, maxLeadingGapPenalty)
            if candidate.wordStart[j] { score += wordStartBonus }
            if j == 0 { score += firstCharacterBonus }
            best[0][j] = score
        }
        if n > 1 {
            for i in 1..<n {
                // Running best of best[i-1][k] + gapPenalty * k over k < j - 1 (non-adjacent predecessors).
                var runningBest = none, runningFrom = -1
                for j in i..<m {
                    let k = j - 2
                    if k >= 0, best[i - 1][k] > none, best[i - 1][k] + gapPenalty * k > runningBest {
                        runningBest = best[i - 1][k] + gapPenalty * k
                        runningFrom = k
                    }
                    guard text[j] == word[i] else { continue }
                    var base = matchScore + (candidate.wordStart[j] ? wordStartBonus : 0)
                    var choice = none, choiceFrom = -1
                    if best[i - 1][j - 1] > none {
                        choice = best[i - 1][j - 1] + adjacentBonus
                        choiceFrom = j - 1
                    }
                    if runningFrom >= 0 {
                        // Gap of j - 1 - k characters.
                        let gapped = runningBest - gapPenalty * (j - 1)
                        if gapped > choice {
                            choice = gapped
                            choiceFrom = runningFrom
                        }
                    }
                    guard choiceFrom >= 0 else { continue }
                    base += choice
                    best[i][j] = base
                    from[i][j] = choiceFrom
                }
            }
        }
        var end = -1, score = none
        for j in 0..<m where best[n - 1][j] > score {
            score = best[n - 1][j]
            end = j
        }
        guard end >= 0 else { return nil }
        var positions = [Int](repeating: 0, count: n)
        var j = end
        for i in stride(from: n - 1, through: 0, by: -1) {
            positions[i] = j
            j = from[i][j]
        }
        return Result(score: score, positions: positions)
    }

    /// `items` that match `query`, best first; ties keep the items' order. All of them, in order, for an empty query.
    public static func rank<Item>(_ items: [Item], query: String, candidate: (Item) -> Candidate) -> [(item: Item, result: Result)] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let scored = items.enumerated().compactMap { offset, item -> (Int, Item, Result)? in
            guard let result = match(trimmed, candidate(item)) else { return nil }
            return (offset, item, result)
        }
        return scored.sorted { a, b in
            a.2.score != b.2.score ? a.2.score > b.2.score : a.0 < b.0
        }.map { (item: $0.1, result: $0.2) }
    }
}
