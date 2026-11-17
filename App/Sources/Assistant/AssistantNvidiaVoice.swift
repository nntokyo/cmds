import AVFoundation
import CmdsCore
import Security
import os

private let nvidiaLog = Logger(subsystem: "tokyo.n-n.cmds", category: "assistant")

/// NVIDIA's hosted voices for the assistant's answers (Settings › Assistant › Voice, "NVIDIA" voices): Magpie TTS
/// Multilingual on build.nvidia.com, called with the user's own API key (`NvidiaKey`). Only the answer's text is sent;
/// the reply's PCM plays here through `AVAudioEngine`, at the rate chosen in Settings (`AVAudioUnitTimePitch`: the
/// service has no rate of its own). Parts are fetched as soon as they are queued and played in order. A part that
/// cannot be fetched (no key, offline, a refused key) is said by the system voice instead, so the assistant never
/// falls silent; `lastError` keeps why for Settings.
@MainActor
final class AssistantNvidiaVoice {
    /// A piece of a part: the utterance number it belongs to, whether it ends the part, its audio once fetched.
    private final class Part {
        let number: Int
        let isLast: Bool
        let text: String
        let language: String
        var audio: AVAudioPCMBuffer?
        var failed = false
        var task: Task<Void, Never>?
        init(number: Int, isLast: Bool, text: String, language: String) {
            self.number = number
            self.isLast = isLast
            self.text = text
            self.language = language
        }
    }

    /// The part `number` started to play / was played (or given up).
    var onStart: ((Int) -> Void)?
    var onEnd: ((Int) -> Void)?
    /// The last failure, for Settings (nil after a part played).
    private(set) static var lastError: String?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(NvidiaSpeech.sampleRate),
                                       channels: 1, interleaved: false)!
    private var queue: [Part] = []
    /// The part playing (its audio scheduled, or said by `fallback`).
    private var playing: Part?
    private var generation = 0
    private let fallback = AVSpeechSynthesizer()
    private let fallbackDelegate = FallbackDelegate()

    init() {
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        fallback.delegate = fallbackDelegate
        fallbackDelegate.ended = { [weak self] in self?.partEnded() }
    }

    /// Whether answers can go to NVIDIA now: an NVIDIA voice is chosen for `language` and a key is set.
    static func voice(for manner: AssistantVoice.Manner) -> String? {
        guard let name = NvidiaSpeech.voiceName(fromSetting: manner.voice),
              NvidiaSpeech.language(ofVoice: name)?.lowercased() == manner.language.lowercased(),
              NvidiaKey.isSet else { return nil }
        return name
    }

    /// Queues `text` (cut into pieces the service takes) as parts of utterance `number`, spoken with `voice`.
    func enqueue(_ text: String, number: Int, voice: String, manner: AssistantVoice.Manner) {
        pitch.rate = Float(Self.playbackRate(manner.rate))
        let pieces = NvidiaSpeech.pieces(text)
        guard !pieces.isEmpty else { return onEnd?(number) ?? () }
        for (index, piece) in pieces.enumerated() {
            // Only the last piece ends the part.
            let part = Part(number: number, isLast: index == pieces.count - 1, text: piece, language: manner.language)
            queue.append(part)
            let generation = generation
            part.task = Task { [weak self] in
                let result = await NvidiaSynthesis.synthesize(piece, language: manner.language, voice: voice)
                guard let self, self.generation == generation else { return }
                switch result {
                case .success(let samples):
                    part.audio = self.buffer(samples)
                    if part.audio == nil { part.failed = true }
                case .failure(let error):
                    Self.lastError = error.description
                    nvidiaLog.error("NVIDIA voice failed: \(error.description, privacy: .public)")
                    part.failed = true
                }
                self.playNext()
            }
        }
    }

    /// Stops at once; parts not played yet are dropped (their utterances end through the caller's `stop`).
    func stop() {
        generation += 1
        queue.forEach { $0.task?.cancel() }
        queue.removeAll()
        playing = nil
        player.stop()
        if fallback.isSpeaking { fallback.stopSpeaking(at: .immediate) }
    }

    var isSpeaking: Bool { playing != nil || !queue.isEmpty }

    /// AVSpeechUtterance rates (0.5 normal) as a playback rate: 0.5 → 1×, the range 0.25…2.5.
    static func playbackRate(_ rate: Double) -> Double { min(max(rate / 0.5, 0.25), 2.5) }

    private func playNext() {
        guard playing == nil, let head = queue.first, head.audio != nil || head.failed else { return }
        queue.removeFirst()
        playing = head
        onStart?(head.number)
        if let audio = head.audio {
            Self.lastError = nil
            do {
                if !engine.isRunning { try engine.start() }
            } catch {
                nvidiaLog.error("NVIDIA voice: audio engine: \(error.localizedDescription, privacy: .public)")
                return speakWithSystemVoice(head)
            }
            let generation = generation
            player.scheduleBuffer(audio, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.generation == generation else { return }
                        self.partEnded()
                    }
                }
            }
            if !player.isPlaying { player.play() }
        } else {
            speakWithSystemVoice(head)
        }
    }

    private func speakWithSystemVoice(_ part: Part) {
        let utterance = AVSpeechUtterance(string: part.text)
        utterance.voice = AVSpeechSynthesisVoice(language: part.language)
        fallback.speak(utterance)
    }

    private func partEnded() {
        guard let part = playing else { return }
        playing = nil
        if part.isLast { onEnd?(part.number) }
        playNext()
    }

    /// Signed 16-bit little-endian mono PCM as a float buffer.
    private func buffer(_ samples: Data) -> AVAudioPCMBuffer? {
        let count = samples.count / 2
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBytes { raw in
            for index in 0..<count {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                channel[index] = Float(sample) / 32768
            }
        }
        buffer.frameLength = AVAudioFrameCount(count)
        return buffer
    }
}

/// The fallback synthesizer's end, back on the main thread.
private final class FallbackDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    @MainActor var ended: (() -> Void)?

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { end() }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {}

    private nonisolated func end() {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.ended?() } }
    }
}

/// Calls to NVIDIA's speech service: the function of Magpie TTS Multilingual (looked up once per run), synthesis and
/// the voice list. HTTP/2 through `URLSession` (gRPC's unary calls need nothing more).
enum NvidiaSynthesis {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private static let cache = FunctionCache()

    /// The PCM samples of `text` spoken by `voice`.
    static func synthesize(_ text: String, language: String, voice: String) async -> Result<Data, Failure> {
        let request = NvidiaSpeech.synthesizeRequest(text: text, language: language, voice: voice)
        switch await call(NvidiaSpeech.synthesizePath, request) {
        case .success(let reply):
            guard let audio = NvidiaSpeech.audio(fromResponse: reply), !audio.isEmpty else {
                return .failure(Failure(description: "the reply has no audio"))
            }
            return .success(audio)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// The voices the service offers (all languages).
    static func voices() async -> Result<[String], Failure> {
        switch await call(NvidiaSpeech.configPath, NvidiaSpeech.configRequest()) {
        case .success(let reply): return .success(NvidiaSpeech.voices(fromConfig: reply))
        case .failure(let error): return .failure(error)
        }
    }

    /// Forgets the function looked up (a new key).
    static func reset() async { await cache.set(nil) }

    private static func call(_ path: String, _ message: Data) async -> Result<Data, Failure> {
        guard let key = NvidiaKey.value else { return .failure(Failure(description: "no NVIDIA API key")) }
        let functionID: String
        switch await function(key: key) {
        case .success(let id): functionID = id
        case .failure(let error): return .failure(error)
        }
        var request = URLRequest(url: URL(string: "https://\(NvidiaSpeech.host)\(path)")!)
        request.httpMethod = "POST"
        for (name, value) in NvidiaSpeech.headers(apiKey: key, functionID: functionID) { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = NvidiaSpeech.frame(message)
        do {
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(Failure(description: "no HTTP reply")) }
            let headers = Dictionary(http.allHeaderFields.compactMap { key, value in
                (key as? String).map { ($0, "\(value)") }
            }, uniquingKeysWith: { first, _ in first })
            if http.statusCode == 401 || http.statusCode == 403 { return .failure(Failure(description: "the API key was refused (HTTP \(http.statusCode))")) }
            if let error = NvidiaSpeech.error(inHeaders: headers) { return .failure(Failure(description: error)) }
            guard http.statusCode == 200 else { return .failure(Failure(description: "HTTP \(http.statusCode)")) }
            guard let reply = NvidiaSpeech.messages(inBody: body)?.first else {
                return .failure(Failure(description: "the reply could not be read"))
            }
            return .success(reply)
        } catch {
            return .failure(Failure(description: error.localizedDescription))
        }
    }

    private static func function(key: String) async -> Result<String, Failure> {
        if let id = await cache.get() { return .success(id) }
        var request = URLRequest(url: NvidiaSpeech.functionsURL)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (body, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { return .failure(Failure(description: "the API key was refused (HTTP \(status))")) }
            guard status == 200, let id = NvidiaSpeech.functionID(in: body) else {
                return .failure(Failure(description: "Magpie TTS Multilingual was not found for this key (HTTP \(status))"))
            }
            await cache.set(id)
            return .success(id)
        } catch {
            return .failure(Failure(description: error.localizedDescription))
        }
    }

    private actor FunctionCache {
        private var id: String?
        func get() -> String? { id }
        func set(_ id: String?) { self.id = id }
    }
}

/// The user's NVIDIA API key (build.nvidia.com, `nvapi-…`), in the login keychain: service "cmds NVIDIA API key",
/// account "nvidia" (the item `security add-generic-password -a nvidia -s "cmds NVIDIA API key" -w` makes too). Never
/// logged, shown or sent anywhere but NVIDIA's API.
enum NvidiaKey {
    static let service = "cmds NVIDIA API key"
    static let account = "nvidia"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static var value: String? {
        var item: CFTypeRef?
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    /// Whether a key is stored (without reading it: no keychain prompt).
    static var isSet: Bool {
        var query = query
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Stores `key` (replacing one), or removes it when empty.
    @discardableResult
    static func set(_ key: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return true }
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
