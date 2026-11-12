import AVFoundation
import CmdsCore

/// Speaks the assistant's answers (#243) with `AVSpeechSynthesizer`, in the app's language, with the voice and rate
/// from Settings › Assistant: a system voice or the user's own Personal Voice (when the user allowed cmds to use it and
/// it speaks the language; else the system voice). Muted: says nothing and reports the end at once. On this Mac only:
/// no cloud speech.
@MainActor
final class AssistantVoice: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var utterances = AssistantUtterances<() -> Void>()
    /// Whom to tell when utterance number … starts.
    private var started: (number: Int, call: (() -> Void)?)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Every voice on this Mac as a plain value (Personal Voices only once cmds may use them).
    static var all: [AssistantVoices.Voice] {
        AVSpeechSynthesisVoice.speechVoices().map {
            AssistantVoices.Voice(identifier: $0.identifier, name: $0.name, language: $0.language,
                                  isPersonal: $0.voiceTraits.contains(.isPersonalVoice), quality: $0.quality.rawValue)
        }
    }

    /// Whether cmds may use the user's Personal Voice; asking is up to Settings' button.
    static var personalVoiceAuthorization: AssistantVoices.Authorization {
        switch AVSpeechSynthesizer.personalVoiceAuthorizationStatus {
        case .authorized: return .authorized
        case .denied: return .denied
        case .unsupported: return .unsupported
        default: return .notDetermined
        }
    }

    /// Asks macOS once whether cmds may use the user's Personal Voice (only from Settings' "Use my Personal Voice…").
    static func requestPersonalVoice(_ done: @escaping @MainActor () -> Void) {
        AVSpeechSynthesizer.requestPersonalVoiceAuthorization { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
        }
    }

    /// How to speak: the language (a BCP 47 code), the chosen voice (nil: the system's) and rate, and whether muted.
    struct Manner: Equatable {
        var language: String
        var voice: String?
        var rate: Double
        var muted: Bool
    }

    /// `started`: the synthesizer began to speak it (#248: never when muted). `open`: more parts follow (`append`),
    /// `finished` runs after `close` and the last part. `queued`: what is being said (an acknowledgement) is not cut
    /// off: this follows it, and its completion is dropped.
    func speak(_ text: String, _ manner: Manner, open: Bool = false, queued: Bool = false, started: (() -> Void)? = nil,
               finished: @escaping () -> Void) {
        if !queued { stop() }
        guard !text.isEmpty || open else { return finished() }
        let number = utterances.start(finished, open: open)
        guard !manner.muted, !text.isEmpty else {
            utterances.ended(number)?()
            return
        }
        self.started = (number, started)
        synthesizer.speak(utterance(text, number: number, manner: manner))
    }

    /// Another part of the open utterance (the next sentence of an answer still being written).
    func append(_ text: String, _ manner: Manner) {
        guard let number = utterances.add() else { return }
        guard !manner.muted, !text.isEmpty else {
            utterances.ended(number)?()
            return
        }
        synthesizer.speak(utterance(text, number: number, manner: manner))
    }

    /// No more parts: the utterance ends after the last one (at once when it has been said).
    func close() {
        utterances.close()?()
    }

    private func utterance(_ text: String, number: Int, manner: Manner) -> AVSpeechUtterance {
        let utterance = NumberedUtterance(string: text)
        // The chosen voice when it speaks the language (a Personal Voice may speak English only), else the system's.
        let chosen = AssistantVoices.resolve(chosen: manner.voice, among: Self.all, language: manner.language).voice
        utterance.voice = chosen.flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) }
            ?? AVSpeechSynthesisVoice(language: manner.language)
        utterance.rate = Float(manner.rate)
        utterance.number = number
        return utterance
    }

    func stop() {
        let pending = utterances.stop()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        pending?()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard let number = (utterance as? NumberedUtterance)?.number else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let started = self.started, started.number == number else { return }
                self.started = nil
                started.call?()
            }
        }
    }

    // A stopped utterance's didCancel (and sometimes didFinish) arrives after the next one has been queued: only the
    // current utterance's callbacks end it (#261).
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        ended(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        ended(utterance)
    }

    private nonisolated func ended(_ utterance: AVSpeechUtterance) {
        guard let number = (utterance as? NumberedUtterance)?.number else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.utterances.ended(number)?() } }
    }
}

/// An utterance with the number `AssistantUtterances` gave it (the synthesizer hands the same object to its delegate).
private final class NumberedUtterance: AVSpeechUtterance, @unchecked Sendable {
    var number = 0
}
