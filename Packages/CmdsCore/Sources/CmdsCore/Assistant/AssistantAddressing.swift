import Foundation

/// Whether an utterance is meant for the assistant (#243). The assistant listens all the time while it is on, so this
/// is what keeps it from acting on conversation: only an utterance that starts with its name (after an optional
/// "hey" / "ねえ"), or one said within a short window after the assistant spoke or the hotkey was pressed, counts.
/// Everything else is discarded by the caller right away and never stored.
public enum AssistantAddressing {
    public enum Result: Equatable, Sendable {
        /// Not for the assistant: drop it.
        case ignored
        /// Only the name ("Jarvis"): wait for the command.
        case wake
        /// A command; `byName` false when it came in the follow-up window without the name.
        case command(String, byName: Bool)
    }

    /// The names used when the user set none.
    public static let defaultNames = ["ジャービス", "Jarvis"]

    /// Words that may come before the name.
    static let greetings = ["hey", "hi", "ok", "okay", "hello", "ねえ", "ねぇ", "ネエ", "おい", "ヘイ", "やあ", "オーケー"]

    /// The names to answer to: the configured one(s) (comma separated), else the defaults. Spellings speech
    /// recognition is known to produce for the defaults are added (`ジャーヴィス`).
    public static func names(configured: String?) -> [String] {
        let configured = (configured ?? "").split(separator: ",").map { AssistantText.trimmed(String($0)) }.filter { !$0.isEmpty }
        return configured.isEmpty ? defaultNames : configured
    }

    /// `followUpOpen`: the assistant just spoke or the hotkey was pressed, so a command without the name counts.
    public static func check(_ utterance: String, names: [String], followUpOpen: Bool) -> Result {
        let text = AssistantText.trimmed(utterance)
        guard !text.isEmpty else { return .ignored }
        if let rest = afterName(text, names: names) {
            return rest.isEmpty ? .wake : .command(rest, byName: true)
        }
        return followUpOpen ? .command(text, byName: false) : .ignored
    }

    /// Longest follow-up taken without the name after an answer: words (Latin script) or characters (Japanese).
    public static let maxFollowUpWords = 8
    public static let maxFollowUpCharacters = 20

    /// Whether `text` is short enough to be a follow-up without the name ("what about tomorrow?", "大阪は？",
    /// "yes"): a long sentence just after the assistant spoke is more likely its own voice or other talk.
    public static func isShortFollowUp(_ text: String) -> Bool {
        let folded = AssistantText.folded(text)
        let latin = folded.unicodeScalars.filter { $0.properties.isAlphabetic }.allSatisfy(\.isASCII)
        if latin { return folded.split(whereSeparator: \.isWhitespace).count <= maxFollowUpWords }
        return AssistantText.key(text).count <= maxFollowUpCharacters
    }

    /// The text after a leading name (and greeting), trimmed; nil when it does not start with one of `names`.
    static func afterName(_ text: String, names: [String]) -> String? {
        let nameKeys = Set(names.map(AssistantText.key).filter { !$0.isEmpty })
        guard !nameKeys.isEmpty else { return nil }
        let targets = nameKeys.union(greetings.flatMap { greeting in nameKeys.map { AssistantText.key(greeting) + $0 } })
        let longest = targets.map(\.count).max() ?? 0
        var prefix = ""
        var index = text.startIndex
        while index < text.endIndex {
            prefix.append(text[index])
            index = text.index(after: index)
            let key = AssistantText.key(prefix)
            if key.count > longest + 1 { return nil }
            guard targets.contains(key) else { continue }
            // A Latin name must end at a word boundary ("Jarvisa" is not "Jarvis").
            if index < text.endIndex, let last = prefix.last, last.isASCII, last.isLetter,
               let next = text[index...].first, next.isASCII, next.isLetter || next.isNumber {
                continue
            }
            // Take what the key leaves out after the name too (a long vowel mark, separators).
            while index < text.endIndex, AssistantText.key(String(text[index])).isEmpty { index = text.index(after: index) }
            return AssistantText.trimmed(String(text[index...]))
        }
        return nil
    }
}
