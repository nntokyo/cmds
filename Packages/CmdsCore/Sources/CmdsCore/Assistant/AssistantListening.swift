import Foundation

/// How the assistant listens (#270, Settings › Assistant › Listening).
public enum AssistantListening: String, CaseIterable, Sendable {
    /// The microphone as it is; an utterance ends by its level (`AssistantEndpoint`).
    case automatic
    /// The same with the system's voice processing on the microphone: noise suppression and echo cancellation.
    case noiseReduction
    /// Only while the listen shortcut is held (a very loud place): letting go ends the utterance at once. With noise
    /// reduction too.
    case pushToTalk

    /// Automatic: voice processing could only be checked with a real microphone, and it ducks other apps' sound while
    /// it runs, so it is the user's choice.
    public static let standard: AssistantListening = .automatic

    /// The system's voice processing (noise suppression, echo cancellation) on the input.
    public var reducesNoise: Bool { self != .automatic }
    /// Every utterance is heard (and needs the name); push to talk hears only what is said while the key is held.
    public var listensAlways: Bool { self != .pushToTalk }

    /// Audio from just before the key went down that is still heard (the first syllable often starts with the press).
    public static let preRoll: TimeInterval = 0.3
    /// Audio after the key came up that is still heard (the last syllable often ends after the release).
    public static let releaseTail: TimeInterval = 0.2
    /// After the release has been finalised, how long a final result may still take before what was recognised so far
    /// is delivered as it is.
    public static let releaseFinalWait: TimeInterval = 1

    /// At most `restartLimit` restarts of the microphone's engine within `restartWindow` seconds: a device that keeps
    /// changing (or voice processing changing it back) must not restart it in a loop.
    public static let restartLimit = 5
    public static let restartWindow: TimeInterval = 10

    /// The restarts of the microphone's engine (`restartLimit` within `restartWindow`).
    public struct Restarts: Sendable {
        private var times: [Date] = []

        public init() {}

        /// A restart at `now`: whether it may happen. Counted either way.
        public mutating func allow(at now: Date) -> Bool {
            times = times.filter { now.timeIntervalSince($0) < AssistantListening.restartWindow } + [now]
            return times.count <= AssistantListening.restartLimit
        }
    }
}
