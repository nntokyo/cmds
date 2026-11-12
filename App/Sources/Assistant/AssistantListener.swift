import AVFoundation
import CmdsCore
import CoreAudio
import CoreMedia
import Speech
import os

private let listenerLog = Logger(subsystem: "tokyo.n-n.cmds", category: "assistant")

/// The microphone, transcribed on the Mac (#243): `AVAudioEngine` feeds `SpeechAnalyzer` with a `SpeechTranscriber`
/// for the app's language. Only finished utterances leave this class (`onUtterance`), as text; the caller drops those
/// not addressed to the assistant right away. Audio is never written anywhere, and partial results are dropped.
///
/// How it listens (#270, `mode`): as the microphone is, with the system's voice processing (noise suppression, echo
/// cancellation), or only while the listen shortcut is held (`push`). Which microphone: `device` (a headset when one
/// is connected, `AssistantInputDevice`), changed while it runs by `restartInput()`.
@available(macOS 26.0, *)
@MainActor
final class AssistantListener {
    enum Failure: Error {
        case microphoneDenied
        case speechDenied
        case languageUnsupported
        case noAudioFormat
    }

    /// A finished utterance: its text, when its speech ended (#248: the last loud moment; nil when unknown) and how it
    /// was heard (#270: a loud room, the recogniser's confidence, push to talk).
    struct Utterance {
        var text: String
        var speechEnd: Date?
        var heard: AssistantHeard
    }

    var onUtterance: ((Utterance) -> Void)?
    /// The input level, 0…1, about 20 times a second.
    var onLevel: ((Float) -> Void)?
    /// Recognition stopped by itself (an error).
    var onStop: ((Error?) -> Void)?
    /// Speech began (the level rose above the room's; #248: the on-device model is warmed up meanwhile).
    var onSpeech: (() -> Void)?

    /// How it listens; takes effect at the next start (the controller restarts it when the setting changes).
    var mode: AssistantListening = .standard
    /// The microphone's Core Audio UID; nil: the system's input. Takes effect at the next start or `restartInput()`.
    var device: String?

    private var engine: AVAudioEngine?
    private var configurationChanges: NSObjectProtocol?
    /// When the engine was last restarted (`restartInput`).
    private var restarts: [Date] = []
    private var analyzer: SpeechAnalyzer?
    /// The analyzer's input and its format, kept while it runs (a new microphone gets a new pump into the same input).
    private var input: (format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation)?
    private var pump: AudioPump?
    private var results: Task<Void, Never>?
    private(set) var isRunning = false
    /// Cleared by `stop()`: a start still waiting (a privacy prompt, the language download) then gives up.
    private var wanted = false
    /// Where the current utterance ends (#248, #270: relative to the room's noise).
    private var endpoint = AssistantEndpoint()
    /// When the level was last shown.
    private var levelShown = Date.distantPast
    /// Finalise at `endpoint` (else only when the recogniser does; `debug.assistant` `hear_audio {endpoint: false}`).
    var finalizesEarly = true
    /// Words recognition should expect (`AnalysisContext.contextualStrings`): the assistant's names, Claude Code,
    /// Codex, cmds, the workspaces' titles and agents.
    private var vocabulary: [String] = []
    /// Push to talk (#270): the key is held, and what was recognised since it went down until it is delivered.
    private(set) var isHeld = false
    private var held: Held?

    private var heldNumber = 0

    private struct Held {
        var number: Int
        var text = ""
        var confidences: [Double] = []
        /// The key came up (and the release tail passed) at this moment; nil while it is held.
        var releasedAt: Date?
        /// The recogniser has finalised everything up to the release.
        var finalized = false
        /// A final result came after the release.
        var finalAfterRelease = false
    }

    #if DEBUG
    /// What `debugFeed` heard (#270, measurements): each final transcript and each early finalisation, in seconds
    /// from the start of the file. Kept until the next `debugFeed`.
    struct DebugRecord {
        var start = Date()
        var finals: [(text: String, at: TimeInterval, noisy: Bool, confidences: [Double])] = []
        var finalizes: [TimeInterval] = []
        var floor: Float = 0
        var done = false
    }
    private(set) var debugRecord: DebugRecord?
    #endif

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
        guard wanted, try await startAnalyzer(locale: locale) else { return }
        try startEngine()
        isRunning = true
    }

    /// The microphone changed (another device chosen or connected, the system's input changed, the engine's
    /// configuration changed): its engine starts again with `device`, into the same recognition.
    func restartInput() {
        guard isRunning, engine != nil else { return }
        // A device that keeps changing (or voice processing changing it back) must not restart it in a loop.
        let now = Date()
        restarts = restarts.filter { now.timeIntervalSince($0) < 10 } + [now]
        guard restarts.count <= 5 else {
            listenerLog.error("assistant microphone keeps changing: not restarted")
            return
        }
        stopEngine()
        do {
            try startEngine()
        } catch {
            listenerLog.error("assistant microphone restart failed: \(String(describing: error), privacy: .public)")
            stopped(error)
        }
    }

    /// A new engine on `device` (with voice processing for `mode`), its tap feeding a new pump into the analyzer.
    private func startEngine() throws {
        guard let input else { return }
        let engine = AVAudioEngine()
        let node = engine.inputNode
        if let device, let id = AssistantAudioDevices.deviceID(uid: device) {
            Self.setDevice(id, of: node)
        }
        if mode.reducesNoise {
            do {
                try node.setVoiceProcessingEnabled(true)
                // Other apps' sound (music, a call) stays as loud as it was.
                node.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                listenerLog.error("assistant voice processing not on: \(String(describing: error), privacy: .public)")
            }
        }
        let format = node.outputFormat(forBus: 0)
        let pump = Self.pump(from: format, to: input.format, continuation: input.continuation, fed: pump?.fedSeconds ?? 0)
        pump.hold(isHeld || mode.listensAlways)
        self.pump = pump
        Self.current = self
        Self.installTap(on: node, format: format, pump: pump)
        engine.prepare()
        self.engine = engine
        // The engine stops when its devices change (the system's input, a headset connected or gone): it starts again.
        configurationChanges = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                      queue: .main) { _ in
            MainActor.assumeIsolated {
                // Only when it did stop (a change it made itself while starting is no reason).
                guard let listener = AssistantListener.current, listener.engine?.isRunning == false else { return }
                listener.restartInput()
            }
        }
        do {
            try engine.start()
        } catch {
            stopEngine()
            throw error
        }
        listenerLog.notice("assistant microphone: \(self.mode.rawValue, privacy: .public), \(self.device == nil ? "system input" : "chosen device", privacy: .public), \(format.channelCount, privacy: .public) ch at \(Int(format.sampleRate), privacy: .public) Hz")
    }

    private func stopEngine() {
        if let configurationChanges { NotificationCenter.default.removeObserver(configurationChanges) }
        configurationChanges = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// The input device of the engine's input node (before it starts).
    private static func setDevice(_ id: AudioDeviceID, of node: AVAudioInputNode) {
        guard let unit = node.audioUnit else { return }
        var id = id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { listenerLog.error("assistant microphone not chosen: \(status, privacy: .public)") }
    }

    // MARK: Push to talk

    /// The listen shortcut went down (true) or up (false) in push to talk (#270): audio goes to recognition only
    /// while it is held (and `AssistantListening.preRoll` before, `releaseTail` after); letting go finalises at once.
    func push(_ down: Bool) {
        guard down != isHeld else { return }
        isHeld = down
        if down {
            // Pressed again before what was said was delivered: it goes on.
            if held == nil {
                heldNumber += 1
                held = Held(number: heldNumber)
            } else {
                held?.releasedAt = nil
                held?.finalized = false
                held?.finalAfterRelease = false
            }
            endpoint.finalized()
            pump?.hold(true)
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(AssistantListening.releaseTail))
            self?.released()
        }
    }

    /// After the release tail: no more audio, and recognition finalises what it has.
    private func released() {
        guard !isHeld, let number = held?.number, let analyzer else { return }
        // Audio still goes in until the utterance is delivered: the recogniser needs a moment after the last word to
        // commit it (cut at once, a short request in noise came back empty).
        held?.releasedAt = Date()
        #if DEBUG
        if let start = debugRecord?.start { debugRecord?.finalizes.append(Date().timeIntervalSince(start)) }
        #endif
        Task { [weak self] in
            do {
                try await analyzer.finalize(through: nil)
            } catch {
                listenerLog.error("assistant finalize failed: \(String(describing: error), privacy: .public)")
            }
            guard let self, self.held?.number == number, !self.isHeld else { return }
            self.held?.finalized = true
            self.deliverHeld()
            // No final yet: it may still come; whatever there is goes after a moment.
            try? await Task.sleep(for: .seconds(1))
            if self.held?.number == number { self.deliverHeld(force: true) }
        }
    }

    /// What was said while the key was held, as one utterance, once recognition finalised it (`force`: as it is).
    private func deliverHeld(force: Bool = false) {
        guard let held, held.releasedAt != nil, !isHeld, held.finalized, held.finalAfterRelease || force else { return }
        self.held = nil
        if !mode.listensAlways { pump?.hold(false) }
        guard !AssistantText.key(held.text).isEmpty else { return }
        let heard = AssistantHeard(noisy: endpoint.isNoisy, confidences: held.confidences, text: held.text, pushed: true)
        onUtterance?(Utterance(text: held.text, speechEnd: endpoint.lastLoud, heard: heard))
    }

    #if DEBUG
    /// `debug.assistant` `hear_audio` (#248): an audio file through the same analyzer as the microphone's, in real time,
    /// then `tail` seconds of faint noise (a quiet room), instead of the microphone (never touched: no permission is
    /// asked, speech is recognised on the Mac). Measures the end of an utterance; stops when it is done.
    /// `release` (#270): push to talk, the key held from the start and let go this many seconds into the file.
    func debugFeed(_ url: URL, locale: Locale, tail: TimeInterval, release: TimeInterval? = nil) async throws {
        guard !isRunning, !wanted else { return }
        wanted = true
        let mode = self.mode
        if release != nil { self.mode = .pushToTalk }
        defer {
            stop()
            self.mode = mode
            debugRecord?.done = true
        }
        let file = try AVAudioFile(forReading: url)
        guard try await startAnalyzer(locale: locale), let input else { return }
        let format = file.processingFormat
        let pump = Self.pump(from: format, to: input.format, continuation: input.continuation, fed: 0)
        pump.hold(self.mode.listensAlways)
        self.pump = pump
        Self.current = self
        isRunning = true
        if release != nil { push(true) }
        let length = Double(file.length) / format.sampleRate
        let start = Date()
        debugRecord = DebugRecord(start: start)
        // Buffers as long as the microphone's (`AssistantTuning.tapBufferSize` at 48 kHz, about 43 ms).
        let frames = AVAudioFrameCount(Double(AssistantTuning.tapBufferSize) * format.sampleRate / 48000)
        var fed = 0.0
        // Far below speech level (`AssistantPresence.Hearing.onLevel` after `AssistantTuning.levelGain`).
        let noise: Float = 0.003
        while wanted, fed < length + tail, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
            if file.framePosition < file.length {
                try file.read(into: buffer, frameCount: frames)
            } else {
                buffer.frameLength = frames
                for channel in 0..<Int(format.channelCount) {
                    guard let samples = buffer.floatChannelData?[channel] else { continue }
                    for index in 0..<Int(buffer.frameLength) { samples[index] = Float.random(in: -noise...noise) }
                }
            }
            pump.push(buffer)
            fed += Double(buffer.frameLength) / format.sampleRate
            if let release, isHeld, fed >= release { push(false) }
            let wait = start.addingTimeInterval(fed).timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        }
    }
    #endif

    /// The analyzer with its transcriber, started (its input in `input`); false when the listener was stopped
    /// meanwhile.
    private func startAnalyzer(locale: Locale) async throws -> Bool {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw Failure.languageUnsupported }
        // The confidence of each word (#270): a name heard in a loud room must be clear.
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults],
                                            attributeOptions: [.transcriptionConfidence])
        // The language model for on-device recognition, downloaded by the system once.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Failure.noAudioFormat
        }
        guard wanted else { return false }
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
            return false
        }
        endpoint = AssistantEndpoint()
        input = (format, continuation)

        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    guard result.isFinal else { continue }
                    self.final(result)
                }
                self?.stopped(nil)
            } catch {
                self?.stopped(error)
            }
        }
        return true
    }

    /// A final result: delivered (punctuation alone, a moment of noise finalised, is nothing), or kept with what the
    /// key is held for.
    private func final(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
        let confidences = Self.confidences(result.text)
        endpoint.finalized()
        #if DEBUG
        if let start = debugRecord?.start {
            debugRecord?.finals.append((text, Date().timeIntervalSince(start), endpoint.isNoisy, confidences))
        }
        #endif
        let speechEnd = speechEnd(of: result.range)
        if held != nil {
            held?.text += text
            held?.confidences += confidences
            if held?.releasedAt != nil { held?.finalAfterRelease = true }
            deliverHeld()
            return
        }
        // Push to talk: nothing is heard without the key (a final of the last audio after it was delivered).
        guard mode.listensAlways, !AssistantText.key(text).isEmpty else { return }
        let heard = AssistantHeard(noisy: endpoint.isNoisy, confidences: confidences, text: text)
        onUtterance?(Utterance(text: text, speechEnd: speechEnd, heard: heard))
    }

    /// The recogniser's confidence for each character of `text` (empty when it gave none).
    private static func confidences(_ text: AttributedString) -> [Double] {
        var values: [Double] = []
        for run in text.runs {
            let count = text[run.range].characters.count
            guard let confidence = run.transcriptionConfidence else { return [] }
            values += Array(repeating: confidence, count: count)
        }
        return values
    }

    /// A pump to the analyzer whose levels reach the current listener on the main actor (made outside the main actor:
    /// the closure runs on the audio thread).
    private nonisolated static func pump(from input: AVAudioFormat, to format: AVAudioFormat,
                                         continuation: AsyncStream<AnalyzerInput>.Continuation, fed: Double) -> AudioPump {
        AudioPump(from: input, to: format, continuation: continuation, fed: fed) { level in
            DispatchQueue.main.async { MainActor.assumeIsolated { AssistantListener.current?.heard(level: level) } }
        }
    }

    /// The level of each buffer: the end of an utterance found by it (`AssistantEndpoint`): speech, then quiet,
    /// relative to the room, and the recogniser is asked to finalise what it has at once (#248, #270). Shown about 20
    /// times a second.
    /// In push to talk only while the key is held (the room's level is followed all the time).
    private func heard(level: Float) {
        let now = Date()
        let began = endpoint.hear(level: level, at: now)
        #if DEBUG
        debugRecord?.floor = endpoint.floor ?? 0
        #endif
        let finalizes = endpoint.shouldFinalize(now: now)
        guard mode.listensAlways || isHeld else { return }
        if began { onSpeech?() }
        if finalizes, finalizesEarly, held == nil, let analyzer {
            #if DEBUG
            if let start = debugRecord?.start { debugRecord?.finalizes.append(now.timeIntervalSince(start)) }
            #endif
            Task {
                do {
                    try await analyzer.finalize(through: nil)
                } catch {
                    listenerLog.error("assistant finalize failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        guard now.timeIntervalSince(levelShown) >= AssistantTuning.levelInterval else { return }
        levelShown = now
        onLevel?(level)
    }

    /// When the speech of a final result ended: the last loud moment, else the end of its audio `range` (in the
    /// analyzer's time) by the audio fed so far. Both delays are logged (#248).
    private func speechEnd(of range: CMTimeRange) -> Date? {
        guard let pump, range.end.isNumeric else { return nil }
        let now = Date()
        let behind = max(0, pump.fedSeconds - range.end.seconds)
        let loud = endpoint.lastLoud.map { now.timeIntervalSince($0) }
        listenerLog.notice("assistant final transcript \(Int(behind * 1000), privacy: .public) ms after its audio ended, \(loud.map { Int($0 * 1000) } ?? -1, privacy: .public) ms after the last loud audio")
        // The last loud moment is when the user stopped speaking (a finalised range ends where it was finalised).
        return endpoint.lastLoud ?? now.addingTimeInterval(-behind)
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
        isHeld = false
        held = nil
        guard isRunning || analyzer != nil else { return }
        isRunning = false
        stopEngine()
        input?.continuation.finish()
        input = nil
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
/// one buffer at a time, nothing more, except in push to talk while the key is up: the last
/// `AssistantListening.preRoll` seconds, so the first syllable said as the key goes down is heard (#270).
@available(macOS 26.0, *)
private final class AudioPump: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let level: @Sendable (Float) -> Void
    private let lock = NSLock()
    private var fed: Double
    /// Audio goes to the analyzer (always, except in push to talk while the key is up).
    private var open = true
    /// Converted audio kept while closed (the pre-roll), oldest first.
    private var kept: [AVAudioPCMBuffer] = []

    /// Seconds of audio handed to the analyzer so far (#248).
    var fedSeconds: Double { lock.withLock { fed } }

    init(from input: AVAudioFormat, to format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
         fed: Double, level: @escaping @Sendable (Float) -> Void) {
        if input == format {
            converter = nil
        } else {
            let converter = AVAudioConverter(from: input, to: format)
            // Voice processing can deliver several channels: mixed down, not just the first taken.
            converter?.downmix = true
            self.converter = converter
        }
        self.format = format
        self.continuation = continuation
        self.fed = fed
        self.level = level
    }

    /// Opens (with the pre-roll kept) or closes the way to the analyzer. The level is measured either way.
    func hold(_ open: Bool) {
        let flushed: [AVAudioPCMBuffer] = lock.withLock {
            self.open = open
            defer { kept = [] }
            return open ? kept : []
        }
        flushed.forEach(yield)
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        let isOpen = lock.withLock { open }
        report(buffer)
        guard let output = converted(buffer) else { return }
        guard isOpen else {
            lock.withLock {
                kept.append(output)
                var seconds = kept.reduce(0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
                while seconds > AssistantListening.preRoll, let first = kept.first {
                    seconds -= Double(first.frameLength) / first.format.sampleRate
                    kept.removeFirst()
                }
            }
            return
        }
        yield(output)
    }

    private func converted(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
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
        return error == nil && output.frameLength > 0 ? output : nil
    }

    private func yield(_ buffer: AVAudioPCMBuffer) {
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        lock.withLock { fed += seconds }
        continuation.yield(AnalyzerInput(buffer: buffer))
    }

    /// RMS of the first channel, scaled for display, for each buffer.
    private func report(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        level(min(1, (sum / Float(buffer.frameLength)).squareRoot() * AssistantTuning.levelGain))
    }
}
