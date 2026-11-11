import Foundation

/// The assistant hearing itself (#243): the microphone stays open while it speaks (so the user can interrupt it by
/// name), and a long answer's transcript can come in seconds after it was said. Such a transcript is dropped when most
/// of it is in what the assistant last said.
public enum AssistantEcho {
    /// The share of a heard utterance's character pairs found in what was said, from which it is an echo.
    public static let threshold = 0.6
    /// Shorter utterances (in `AssistantText.key` characters: "はい", "yes", a workspace's name) are never echoes: the
    /// answer to the assistant's own question is often in it.
    public static let minimumLength = 6

    /// Whether `heard` is (mostly) the assistant's own `spoken` text, compared as `AssistantText.key` (width, case,
    /// kana, punctuation and spaces folded) by character pairs, so recognition errors and a cut start or end still count.
    public static func isEcho(_ heard: String, of spoken: String) -> Bool {
        let heard = Array(AssistantText.key(heard))
        guard heard.count >= minimumLength else { return false }
        let said = Array(AssistantText.key(spoken))
        guard said.count >= 2 else { return false }
        let saidPairs = Set((0..<(said.count - 1)).map { String(said[$0...$0 + 1]) })
        let pairs = (0..<(heard.count - 1)).map { String(heard[$0...$0 + 1]) }
        let found = pairs.count { saidPairs.contains($0) }
        return Double(found) / Double(pairs.count) >= threshold
    }
}
