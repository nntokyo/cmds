import Foundation

/// When an utterance has ended (#248, #270). Speech recognition (`SpeechTranscriber`) finalises a Japanese utterance
/// only seconds after the speech (about 7–10 s of quiet in tests with recorded speech fed in real time; English about
/// 2 s), so the listener asks it to finalise what it has (`SpeechAnalyzer.finalize`) once the microphone has been
/// quiet for `quiet` after at least `minimumSpeech` of speech. (Its `fastResults` option would give early volatile
/// results to decide on, but makes the final transcript worse: 「APIの」 became 「AP来の」.)
///
/// Speech and quiet are relative to the room (#270): the level of the room without speech (`floor`, its noise floor)
/// is followed all the time, quickly down and slowly up, and speech is a level clearly above it (`speechMargin`), so
/// the end of an utterance is found in a café or on a platform too, where the level never drops to a quiet room's.
/// In a quiet room speech still needs `minimumLevel`. When the noise rises and falls as much as speech (babble close
/// by), the recogniser's own end of utterance still counts, as before.
public struct AssistantEndpoint: Equatable, Sendable {
    /// Quiet after speech that ends an utterance: longer than a pause between words or a breath inside a sentence.
    public static let quiet: TimeInterval = 0.8
    /// Speech for at least this long (first to last loud moment) counts as speech, not a click or a cough.
    public static let minimumSpeech: TimeInterval = 0.3
    /// Speech is at least this level (the shown level, 0…1) even in a quiet room.
    public static let minimumLevel: Float = AssistantPresence.Hearing.onLevel
    /// Speech begins at this many times the room's level (6 dB above its noise)…
    public static let speechMargin: Float = 2
    /// …and goes on while it stays above this many times (3.5 dB), so a softer word inside a sentence does not end it.
    public static let continueMargin: Float = 1.5
    /// Buffers in a row above that level (about 43 ms each) that count as sound: a clink or a knock is shorter.
    public static let sustain = 2
    /// How fast the floor follows a louder room (time constant): slowly, so speech does not lift it much, but a train
    /// pulling in becomes the new floor within seconds.
    public static let floorRise: TimeInterval = 3
    /// How fast the floor follows a quieter room (time constant).
    public static let floorFall: TimeInterval = 0.25
    /// A room whose floor is this loud is noisy (`isNoisy`: the name is checked more strictly). A quiet room is about
    /// 0.02–0.05.
    public static let noisyFloor: Float = 0.08

    /// The first loud moment of the speech not finalised yet.
    public private(set) var speechStarted: Date?
    /// The last loud moment (of speech since the last final result, or before).
    public private(set) var lastLoud: Date?
    /// The room's level without speech (nil until the first level).
    public private(set) var floor: Float?
    private var lastLevel: Date?
    /// Speech since `speechStarted`, not finalised yet.
    private var inSpeech = false
    /// Loud buffers in a row, and when the first of them came.
    private var loudRun = 0
    private var loudSince: Date?

    public init() {}

    /// The level speech needs now (to begin, or to go on).
    public var threshold: Float {
        max(Self.minimumLevel, (floor ?? 0) * (inSpeech ? Self.continueMargin : Self.speechMargin))
    }

    /// The room is loud (its floor is above `noisyFloor`).
    public var isNoisy: Bool { (floor ?? 0) >= Self.noisyFloor }

    /// The microphone's level (0…1, each buffer). True when speech began with it.
    @discardableResult
    public mutating func hear(level: Float, at date: Date) -> Bool {
        let loud = level >= threshold
        follow(level, at: date)
        guard loud else {
            loudRun = 0
            return false
        }
        if loudRun == 0 { loudSince = date }
        loudRun += 1
        guard loudRun >= Self.sustain else { return false }
        let began = !inSpeech
        if began { speechStarted = loudSince ?? date }
        inSpeech = true
        lastLoud = date
        return began
    }

    /// The floor follows the level in decibels: down within `floorFall`, up within `floorRise`.
    private mutating func follow(_ level: Float, at date: Date) {
        let decibels = 20 * log10(max(Double(level), 1e-4))
        defer { lastLevel = date }
        guard let floor, let lastLevel else {
            self.floor = Float(pow(10, decibels / 20))
            return
        }
        let current = 20 * log10(max(Double(floor), 1e-4))
        let elapsed = min(max(date.timeIntervalSince(lastLevel), 0), 1)
        let constant = decibels > current ? Self.floorRise : Self.floorFall
        let next = current + (decibels - current) * (1 - exp(-elapsed / constant))
        self.floor = Float(pow(10, next / 20))
    }

    /// The recogniser delivered a final result: what was said so far is done.
    public mutating func finalized() {
        speechStarted = nil
        inSpeech = false
    }

    /// Whether to finalise now: speech, then `quiet`. True once per stretch of speech (the caller then asks the
    /// recogniser to finalise; its final result, or the next speech, starts the next one).
    public mutating func shouldFinalize(now: Date) -> Bool {
        guard inSpeech, let speechStarted, let lastLoud, now.timeIntervalSince(lastLoud) >= Self.quiet else { return false }
        // Too short for speech (a click): forgotten, so it does not join the next speech.
        let speech = lastLoud.timeIntervalSince(speechStarted) >= Self.minimumSpeech
        finalized()
        return speech
    }
}
