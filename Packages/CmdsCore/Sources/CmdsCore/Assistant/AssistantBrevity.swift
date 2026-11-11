import Foundation

/// Short answers (#243): what is spoken is at most the first sentence of a long answer; the HUD shows it all.
public enum AssistantBrevity {
    /// Answers up to this long (`spokenLength`) are spoken whole.
    public static let maxSpokenLength = 100

    /// Length as it takes to say: a Latin letter or digit counts 1, a Japanese character 2 (about the same time).
    public static func spokenLength(_ text: String) -> Int {
        text.reduce(0) { $0 + ($1.isASCII ? 1 : 2) }
    }

    /// The sentences of `text`: each ends after `。！？!?…`, a line break, or a `.` before a space or the end (not
    /// "19.5" or "v1.2").
    public static func sentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if character.isNewline {
                append(&current, to: &sentences)
                continue
            }
            current.append(character)
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let ends: Bool
            switch character {
            case "。", "！", "？", "!", "?", "…": ends = next.map { !"。！？!?…」』）)\"”".contains($0) } ?? true
            case ".": ends = next == nil || next!.isWhitespace
            default: ends = false
            }
            if ends { append(&current, to: &sentences) }
        }
        append(&current, to: &sentences)
        return sentences
    }

    private static func append(_ current: inout String, to sentences: inout [String]) {
        let sentence = current.trimmingCharacters(in: .whitespaces)
        if !sentence.isEmpty { sentences.append(sentence) }
        current = ""
    }

    /// At most the first `count` sentences, joined as they were (Japanese without a space).
    public static func first(_ count: Int, of text: String) -> String {
        let all = sentences(text)
        guard all.count > count else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return join(Array(all.prefix(count)))
    }

    /// What to say of an answer: all of it when short, else its first sentence.
    public static func spoken(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard spokenLength(trimmed) > maxSpokenLength else { return trimmed }
        return sentences(trimmed).first ?? trimmed
    }

    private static func join(_ sentences: [String]) -> String {
        var text = ""
        for sentence in sentences {
            // "Done. Next." with a space, "完了。次。" without.
            if let last = text.last, last.isASCII { text += " " }
            text += sentence
        }
        return text
    }
}
