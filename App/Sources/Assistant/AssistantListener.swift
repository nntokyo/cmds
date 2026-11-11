import AVFoundation
import Speech
import os

private let listenerLog = Logger(subsystem: "tokyo.n-n.cmds", category: "assistant")

/// The microphone, transcribed on the Mac (#243): `AVAudioEngine` feeds `SpeechAnalyzer` with a `SpeechTranscriber`
/// for the app's language. Only finished utterances leave this class (`onUtterance`), as text; the caller drops those
/// not addressed to the assistant right away. Audio is never written anywhere, and partial results are dropped.
@available(macOS 26.0, *)
@MainActor
final class AssistantListener {
    enum Failure: Error {
        case microphoneDenied
        case speechDenied
        case languageUnsupported
        case noAudioFormat
    }

    /// A finished utterance.
    var onUtterance: ((String) -> Void)?
    /// The input level, 0…1, about 20 times a second.
    var onLevel: ((Float) -> Void)?
    /// Recognition stopped by itself (an error).
    var onStop: ((Error?) -> Void)?

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var pump: AudioPump?
    private var results: Task<Void, Never>?
    private(set) var isRunning = false
    /// Cleared by `stop()`: a start still waiting (a privacy prompt, the language download) then gives up.
    private var wanted = false
    /// Words recognition should expect (`AnalysisContext.contextualStrings`): the assistant's names, Claude Code,
    /// Codex, cmds, the workspaces' titles and agents.
    private var vocabulary: [String] = []

    /// The words to expect, now and for the next start.
    func setVocabulary(_ words: [String]) {
        vocabulary = words
        guard let analyzer else { return }
        let context = Self.context(words)
        Task {
            do {
                try await analyzer.setContext(context)
            } catch {
                listenerLog.error("assistant vocabulary not set: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static func context(_ words: [String]) -> AnalysisContext {
        let context = AnalysisContext()
        context.contextualStrings = [.general: words]
        return context
    }

    /// Asks for the microphone (and, for the transcriber, speech recognition) the first time; macOS shows its own
    /// prompts, worded by NSMicrophoneUsageDescription / NSSpeechRecognitionUsageDescription.
    static func authorize() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Failure.microphoneDenied }
        default: throw Failure.microphoneDenied
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: break
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard status == .authorized else { throw Failure.speechDenied }
        default: throw Failure.speechDenied
        }
    }

    func start(locale: Locale) async throws {
        guard !isRunning, !wanted else { return }
        wanted = true
        try await Self.authorize()
        guard wanted else { return }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw Failure.languageUnsupported }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults],
                                            attributeOptions: [])
        // The language model for on-device recognition, downloaded by the system once.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Failure.noAudioFormat
        }
        guard wanted else { return }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            try await analyzer.setContext(Self.context(vocabulary))
        } catch {
            listenerLog.error("assistant vocabulary not set: \(String(describing: error), privacy: .public)")
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
        guard wanted else {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            self.analyzer = nil
            return
        }

        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard let self else { return }
                    if result.isFinal, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.onUtterance?(text) }
                }
                self?.stopped(nil)
            } catch {
                self?.stopped(error)
            }
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let pump = AudioPump(from: inputFormat, to: format, continuation: continuation) { level in
            DispatchQueue.main.async { MainActor.assumeIsolated { AssistantListener.current?.onLevel?(level) } }
        }
        self.pump = pump
        Self.current = self
        Self.installTap(on: input, format: inputFormat, pump: pump)
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    /// The listener the audio thread reports levels to.
    private static weak var current: AssistantListener?

    /// The tap block runs on the audio thread: made outside the main actor, so it is not isolated to it (a block
    /// formed in a main-actor method would trap when called there).
    private nonisolated static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, pump: AudioPump) {
        input.installTap(onBus: 0, bufferSize: AssistantTuning.tapBufferSize, format: format) { buffer, _ in pump.push(buffer) }
    }

    func stop() {
        wanted = false
        guard isRunning || analyzer != nil else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        pump?.finish()
        pump = nil
        results?.cancel()
        results = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
    }

    private func stopped(_ error: Error?) {
        guard isRunning else { return }
        stop()
        onStop?(error)
    }
}

/// On the audio thread: converts the microphone's buffers to the analyzer's format and measures their level. Holds
/// one buffer at a time, nothing more.
@available(macOS 26.0, *)
private final class AudioPump: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let level: @Sendable (Float) -> Void
    private var lastLevel = Date.distantPast

    init(from input: AVAudioFormat, to format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
         level: @escaping @Sendable (Float) -> Void) {
        converter = input == format ? nil : AVAudioConverter(from: input, to: format)
        self.format = format
        self.continuation = continuation
        self.level = level
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        report(buffer)
        guard let converter else {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, output.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: output)) }
    }

    func finish() { continuation.finish() }

    /// RMS of the first channel, scaled for display, at most 20 times a second.
    private func report(_ buffer: AVAudioPCMBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastLevel) >= AssistantTuning.levelInterval, let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        lastLevel = now
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        level(min(1, rms * AssistantTuning.levelGain))
    }
}
