import Foundation

/// When an utterance has ended (#248). Speech recognition (`SpeechTranscriber`) finalises a Japanese utterance only
/// seconds after the speech (about 7–10 s of quiet in tests with recorded speech fed in real time; English about 2 s),
/// so the listener asks it to finalise what it has (`SpeechAnalyzer.finalize`) once the microphone has been quiet for
/// `quiet` after at least `minimumSpeech` of sound at speech level. In a room loud enough to keep the level up nothing
/// changes: the recogniser's own end of utterance counts, as before. (Its `fastResults` option would give early
/// volatile results to decide on, but makes the final transcript worse: 「APIの」 became 「AP来の」.)
public struct AssistantEndpoint: Equatable, Sendable {
    /// Quiet after speech that ends an utterance: longer than a pause between words or a breath inside a sentence.
    public static let quiet: TimeInterval = 0.8
    /// Sound at speech level for at least this long (first to last loud moment) counts as speech, not a click or a cough.
    public static let minimumSpeech: TimeInterval = 0.3

    /// The first and the last loud moment of the speech not finalised yet.
    public private(set) var speechStarted: Date?
    private var lastLoud: Date?

    public init() {}

    /// The microphone heard something at speech level.
    public mutating func loud(at date: Date) {
        if speechStarted == nil { speechStarted = date }
        lastLoud = date
    }

    /// The recogniser delivered a final result: what was said so far is done.
    public mutating func finalized() {
        speechStarted = nil
        lastLoud = nil
    }

    /// Whether to finalise now: speech, then `quiet`. True once per stretch of speech (the caller then asks the
    /// recogniser to finalise; its final result, or the next speech, starts the next one).
    public mutating func shouldFinalize(now: Date) -> Bool {
        guard let speechStarted, let lastLoud, now.timeIntervalSince(lastLoud) >= Self.quiet else { return false }
        // Too short for speech (a click): forgotten, so it does not join the next speech.
        let speech = lastLoud.timeIntervalSince(speechStarted) >= Self.minimumSpeech
        finalized()
        return speech
    }
}
