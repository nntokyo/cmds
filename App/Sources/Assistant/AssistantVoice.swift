import AVFoundation

/// Speaks the assistant's answers (#243) with `AVSpeechSynthesizer`, in the app's language, with the voice and rate
/// from Settings › Assistant. Muted: says nothing and reports the end at once.
@MainActor
final class AssistantVoice: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var finished: (() -> Void)?
    /// The output level while speaking (a pulse for the orb), driven by a timer since the synthesizer gives none.
    private(set) var isSpeaking = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// The voices for a language, best quality first (Settings' popup).
    static func voices(language: String) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(String(language.prefix(2))) }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    func speak(_ text: String, language: String, voice identifier: String?, rate: Double, muted: Bool,
               finished: @escaping () -> Void) {
        stop()
        guard !muted, !text.isEmpty else { return finished() }
        let utterance = AVSpeechUtterance(string: text)
        let chosen = identifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
        utterance.voice = chosen.flatMap { $0.language.hasPrefix(String(language.prefix(2))) ? $0 : nil }
            ?? AVSpeechSynthesisVoice(language: language)
        utterance.rate = Float(rate)
        self.finished = finished
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        let pending = finished
        finished = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
        pending?()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.done() } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.done() } }
    }

    private func done() {
        isSpeaking = false
        let pending = finished
        finished = nil
        pending?()
    }
}
