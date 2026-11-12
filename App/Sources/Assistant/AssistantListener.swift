import AVFoundation
import CmdsCore
import CoreMedia
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

    /// A finished utterance, and when its speech ended (#248: the end of the audio it was recognised from, by the
    /// audio fed since; nil when unknown).
    var onUtterance: ((String, Date?) -> Void)?
    /// The input level, 0…1, about 20 times a second.
    var onLevel: ((Float) -> Void)?
    /// Recognition stopped by itself (an error).
    var onStop: ((Error?) -> Void)?
    /// Speech began (the level rose after quiet; #248: the on-device model is warmed up meanwhile).
    var onSpeech: (() -> Void)?

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var pump: AudioPump?
    private var results: Task<Void, Never>?
    private(set) var isRunning = false
    /// The microphone's engine runs (not for `debugFeed`).
    private var usesEngine = false
    /// Cleared by `stop()`: a start still waiting (a privacy prompt, the language download) then gives up.
    private var wanted = false
    /// Where the current utterance ends (#248).
    private var endpoint = AssistantEndpoint()
    /// Finalise at `endpoint` (else only when the recogniser does; `debug.assistant` `hear_audio {endpoint: false}`).
    var finalizesEarly = true
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
        guard wanted, let started = try await startAnalyzer(locale: locale) else { return }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let pump = attachPump(from: inputFormat, to: started)
        Self.installTap(on: input, format: inputFormat, pump: pump)
        usesEngine = true
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    #if DEBUG
    /// `debug.assistant` `hear_audio` (#248): an audio file through the same analyzer as the microphone's, in real time,
    /// then `tail` seconds of faint noise (a quiet room), instead of the microphone (never touched: no permission is
    /// asked, speech is recognised on the Mac). Measures the end of an utterance; stops when it is done.
    func debugFeed(_ url: URL, locale: Locale, tail: TimeInterval) async throws {
        guard !isRunning, !wanted else { return }
        wanted = true
        defer { stop() }
        let file = try AVAudioFile(forReading: url)
        guard let started = try await startAnalyzer(locale: locale) else { return }
        let format = file.processingFormat
        let pump = attachPump(from: format, to: started)
        isRunning = true
        let length = Double(file.length) / format.sampleRate
        let start = Date()
        var fed = 0.0
        // Far below speech level (`AssistantPresence.Hearing.onLevel` after `AssistantTuning.levelGain`).
        let noise: Float = 0.003
        while wanted, fed < length + tail,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AssistantTuning.tapBufferSize) {
            if file.framePosition < file.length {
                try file.read(into: buffer, frameCount: AssistantTuning.tapBufferSize)
            } else {
                buffer.frameLength = AssistantTuning.tapBufferSize
                for channel in 0..<Int(format.channelCount) {
                    guard let samples = buffer.floatChannelData?[channel] else { continue }
                    for index in 0..<Int(buffer.frameLength) { samples[index] = Float.random(in: -noise...noise) }
                }
            }
            pump.push(buffer)
            fed += Double(buffer.frameLength) / format.sampleRate
            let wait = start.addingTimeInterval(fed).timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        }
    }
    #endif

    /// The analyzer with its transcriber, started; nil when the listener was stopped meanwhile. Its input goes in
    /// through the continuation, in `format`.
    private func startAnalyzer(locale: Locale) async throws
        -> (format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation)? {
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
        guard wanted else { return nil }
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
            return nil
        }
        endpoint = AssistantEndpoint()

        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard let self else { return }
                    guard result.isFinal else { continue }
                    self.endpoint.finalized()
                    // Punctuation alone (finalising a moment of noise) is nothing.
                    if !AssistantText.key(text).isEmpty { self.onUtterance?(text, self.speechEnd(of: result.range)) }
                }
                self?.stopped(nil)
            } catch {
                self?.stopped(error)
            }
        }

        return (format, continuation)
    }

    /// The pump from audio in `input`'s format to the analyzer just `started`, kept, its levels reported to this
    /// listener (the microphone's and `debugFeed`'s alike).
    private func attachPump(from input: AVAudioFormat,
                            to started: (format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation)) -> AudioPump {
        let pump = Self.pump(from: input, to: started.format, continuation: started.continuation)
        self.pump = pump
        Self.current = self
        return pump
    }

    /// A pump to the analyzer whose levels reach the current listener on the main actor (made outside the main actor:
    /// the closure runs on the audio thread).
    private nonisolated static func pump(from input: AVAudioFormat, to format: AVAudioFormat,
                                         continuation: AsyncStream<AnalyzerInput>.Continuation) -> AudioPump {
        AudioPump(from: input, to: format, continuation: continuation) { level in
            DispatchQueue.main.async { MainActor.assumeIsolated { AssistantListener.current?.heard(level: level) } }
        }
    }

    /// The level, about 20 times a second: shown, and the end of an utterance found by it (`AssistantEndpoint`):
    /// speech, then quiet, and the recogniser is asked to finalise what it has at once (#248).
    private func heard(level: Float) {
        let now = Date()
        if level >= AssistantPresence.Hearing.onLevel {
            let began = endpoint.speechStarted == nil
            endpoint.loud(at: now)
            if began { onSpeech?() }
        }
        if endpoint.shouldFinalize(now: now), finalizesEarly, let analyzer {
            Task {
                do {
                    try await analyzer.finalize(through: nil)
                } catch {
                    listenerLog.error("assistant finalize failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        onLevel?(level)
    }

    /// When the speech of a final result ended: the last loud moment, else the end of its audio `range` (in the
    /// analyzer's time) by the audio fed so far. Both delays are logged (#248).
    private func speechEnd(of range: CMTimeRange) -> Date? {
        guard let pump, range.end.isNumeric else { return nil }
        let now = Date()
        let behind = max(0, pump.fedSeconds - range.end.seconds)
        let loud = pump.lastLoud.map { now.timeIntervalSince($0) }
        listenerLog.notice("assistant final transcript \(Int(behind * 1000), privacy: .public) ms after its audio ended, \(loud.map { Int($0 * 1000) } ?? -1, privacy: .public) ms after the last loud audio")
        // The last loud moment is when the user stopped speaking (a finalised range ends where it was finalised).
        return pump.lastLoud ?? now.addingTimeInterval(-behind)
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
        if usesEngine {
            usesEngine = false
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
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
    private let lock = NSLock()
    private var fed: Double = 0
    private var loudAt: Date?

    /// Seconds of audio handed to the analyzer so far (#248).
    var fedSeconds: Double { lock.withLock { fed } }
    /// The last buffer at least as loud as speech (`AssistantPresence.Hearing`'s threshold).
    var lastLoud: Date? { lock.withLock { loudAt } }

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
            fed(buffer)
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
        if error == nil, output.frameLength > 0 {
            fed(output)
            continuation.yield(AnalyzerInput(buffer: output))
        }
    }

    private func fed(_ buffer: AVAudioPCMBuffer) {
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        lock.withLock { fed += seconds }
    }

    func finish() { continuation.finish() }

    /// RMS of the first channel, scaled for display, at most 20 times a second.
    private func report(_ buffer: AVAudioPCMBuffer) {
        let now = Date()
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let value = min(1, (sum / Float(buffer.frameLength)).squareRoot() * AssistantTuning.levelGain)
        if value >= AssistantPresence.Hearing.onLevel { lock.withLock { loudAt = now } }
        guard now.timeIntervalSince(lastLevel) >= AssistantTuning.levelInterval else { return }
        lastLevel = now
        level(value)
    }
}
