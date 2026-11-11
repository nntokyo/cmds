import AVFoundation
import CmdsCore

/// Speaks the assistant's answers (#243) with `AVSpeechSynthesizer`, in the app's language, with the voice and rate
/// from Settings › Assistant: a system voice or the user's own Personal Voice (when the user allowed cmds to use it and
/// it speaks the language; else the system voice). Muted: says nothing and reports the end at once. On this Mac only:
/// no cloud speech.
@MainActor
final class AssistantVoice: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var finished: (() -> Void)?

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

    func speak(_ text: String, language: String, voice identifier: String?, rate: Double, muted: Bool,
               finished: @escaping () -> Void) {
        stop()
        guard !muted, !text.isEmpty else { return finished() }
        let utterance = AVSpeechUtterance(string: text)
        // The chosen voice when it speaks the language (a Personal Voice may speak English only), else the system's.
        let chosen = AssistantVoices.resolve(chosen: identifier, among: Self.all, language: language).voice
        utterance.voice = chosen.flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) } ?? AVSpeechSynthesisVoice(language: language)
        utterance.rate = Float(rate)
        self.finished = finished
        synthesizer.speak(utterance)
    }

    func stop() {
        let pending = finished
        finished = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        pending?()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.done() } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.done() } }
    }

    private func done() {
        let pending = finished
        finished = nil
        pending?()
    }
}
