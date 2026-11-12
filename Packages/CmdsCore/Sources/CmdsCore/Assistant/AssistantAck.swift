import Foundation

/// The short acknowledgement for a slow answer (#248): 「調べます。」 / "Checking." once Claude has been at it for
/// `delay` without an answer, so the user hears at once that the question was taken. Never for a fast answer, never
/// over the assistant's own voice, never twice.
public enum AssistantAck {
    /// How long a slow answer may take before the acknowledgement.
    public static let delay: TimeInterval = 0.8

    /// Whether to say it now: a slow path (`claude -p` for the answer), still thinking about the same request, nothing
    /// said for it yet and the voice free.
    public static func due(slow: Bool, elapsed: TimeInterval, thinking: Bool, said: Bool, voiceActive: Bool) -> Bool {
        slow && elapsed >= delay && thinking && !said && !voiceActive
    }
}
