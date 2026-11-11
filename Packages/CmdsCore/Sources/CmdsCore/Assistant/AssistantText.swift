import Foundation

/// Text helpers of the voice assistant (#243): what speech recognition gives differs in width, case, kana and
/// punctuation from what the user configured or the workspaces are called.
public enum AssistantText {
    /// Width and case folded (NFKC, lower case), hiragana as katakana, `ヴィ` / `ヴ` as `ビ` / `ブ`, whitespace collapsed
    /// and trimmed. Punctuation stays.
    public static func folded(_ text: String) -> String {
        var value = text.precomposedStringWithCompatibilityMapping.lowercased()
        value = value.applyingTransform(.hiraganaToKatakana, reverse: false) ?? value
        for (from, to) in [("ヴァ", "バ"), ("ヴィ", "ビ"), ("ヴェ", "ベ"), ("ヴォ", "ボ"), ("ヴ", "ブ")] {
            value = value.replacingOccurrences(of: from, with: to)
        }
        return value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `folded` without spaces, punctuation, symbols and the long vowel mark: what two spellings of a name have in
    /// common (`ジャーヴィス`, `じゃーびす`, `ジャービス、` all give `ジャビス`).
    public static func key(_ text: String) -> String {
        let folded = folded(text)
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar) || scalar == "ー" || scalar == "・" {
                continue
            }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// Separators that may follow the assistant's name or end an utterance.
    static let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,!?;:。、，．！？；：…"))

    /// `text` without leading and trailing separators (spaces, `、`, `。`, `,`, `!`, `?`).
    public static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: separators)
    }

    /// The numbers 1–9 as said: digits (also full width), kanji, English words and ordinals.
    static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
        "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
        "いち": 1, "に": 2, "さん": 3, "よん": 4, "ご": 5, "ろく": 6, "なな": 7, "はち": 8, "きゅう": 9,
    ]

    /// 1–9 from a digit or a number word; nil otherwise.
    public static func number(_ word: String) -> Int? {
        let value = trimmed(word.precomposedStringWithCompatibilityMapping.lowercased())
        if let number = Int(value), (1...9).contains(number) { return number }
        return numberWords[value]
    }
}

/// A small wrapper over `NSRegularExpression` (case-insensitive) for the intent grammar.
struct Pattern: Sendable {
    nonisolated(unsafe) let regex: NSRegularExpression
    /// The same, matching the whole text only.
    nonisolated(unsafe) let whole: NSRegularExpression

    init(_ pattern: String) {
        // Patterns are literals in this module; a bad one is a programming error caught by the tests.
        regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        whole = try! NSRegularExpression(pattern: "^(?:" + pattern + ")$", options: [.caseInsensitive])
    }

    /// The capture groups of a match of the whole text (nil for groups that did not take part).
    func match(_ text: String) -> [String?]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let result = whole.firstMatch(in: text, options: [], range: range) else { return nil }
        return (1..<max(result.numberOfRanges, 1)).map { index in
            Range(result.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    /// Whether the pattern occurs anywhere in the text.
    func occurs(in text: String) -> Bool {
        regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
    }
}
