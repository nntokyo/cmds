import Foundation

/// How an utterance was heard (#270), for the checks that depend on it.
public struct AssistantHeard: Equatable, Sendable {
    /// The room was loud (`AssistantEndpoint.isNoisy`): the name is checked more strictly
    /// (`AssistantAddressing.noisyNameConfidence`); follow-ups without it are as in a quiet room.
    public var noisy: Bool
    /// The recogniser's confidence for each character of `text` (0…1); empty when it gave none.
    public var confidences: [Double]
    /// The utterance as recognised (untrimmed), which `confidences` belong to; nil: the one checked.
    public var text: String?
    /// Said while the listen shortcut was held (push to talk): meant for the assistant, without its name.
    public var pushed: Bool

    public init(noisy: Bool = false, confidences: [Double] = [], text: String? = nil, pushed: Bool = false) {
        self.noisy = noisy
        self.confidences = confidences
        self.text = text
        self.pushed = pushed
    }
}
