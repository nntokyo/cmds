import Foundation

/// How long each stage of one request took (#248): from the utterance heard to the voice starting, for
/// `debug.assistant` and one log line per request (stage names and milliseconds only, never what was said).
public struct AssistantTimeline: Equatable, Sendable {
    /// The stages, in the order they usually happen. Each is noted once, the first time (`done` stages the last time:
    /// a list of summaries asks the model or Claude once per session).
    public enum Stage: String, CaseIterable, Sendable {
        /// The last loud audio before the transcript (microphone only): before `heard`, so negative.
        case speechEnd
        /// The final transcript arrived (the timeline's zero).
        case heard
        /// The rules planned it.
        case routed
        case interpreterStart, interpreterDone
        case modelStart, modelDone
        case claudeSpawn, claudeFirstByte, claudeFirstText, claudeDone
        /// The short acknowledgement ("調べます。") was said.
        case ack
        /// The answer (or its first sentence) went to the voice.
        case speechStart
        /// The synthesizer started speaking it (not when muted).
        case voiceStart

        var isDone: Bool { self == .interpreterDone || self == .modelDone || self == .claudeDone }
    }

    /// Which way a request went, as `debug.assistant` and the log name it; the last one set counts ("model", then
    /// "model+web").
    public enum Route: String, Sendable {
        /// Answered by the rules (the status, a workspace's report, a note).
        case rules
        /// Asked back ("Which one: api, api-v2?").
        case askBack
        /// A card to confirm.
        case card
        /// A session's summary by the on-device model, or by Claude when detailed.
        case summary
        case claudeSummary
        /// A summary of each of several sessions.
        case summaries
        /// The interpreter first (`AssistantRoute.interpreter`).
        case interpreter
        /// The interpreter and the on-device model at once (`AssistantRoute.interpreterAndModel`).
        case interpreterOrModel = "interpreter|model"
        /// The on-device model's answer after the interpreter found no command.
        case interpreterThenModel = "interpreter+model"
        case model
        /// The on-device model said it needs the web.
        case modelThenWeb = "model+web"
        case web
        /// A web answer from `AssistantWebCache`.
        case webCache = "web-cache"
    }

    public let request: Int
    public let start: Date
    /// Which way the request went, set as it goes.
    public var route: Route?
    public private(set) var marks: [Stage: TimeInterval] = [:]

    public init(request: Int, start: Date) {
        self.request = request
        self.start = start
    }

    /// Notes `stage` at `date`; once, except the end of a model or Claude call (the last one counts).
    public mutating func mark(_ stage: Stage, at date: Date = Date()) {
        guard marks[stage] == nil || stage.isDone else { return }
        marks[stage] = date.timeIntervalSince(start)
    }

    /// Milliseconds from `heard` per stage noted.
    public var milliseconds: [String: Int] {
        Dictionary(uniqueKeysWithValues: marks.map { ($0.key.rawValue, Int(($0.value * 1000).rounded())) })
    }

    /// When the user first heard something back: the acknowledgement or the answer, in milliseconds.
    public var firstSound: Int? {
        [marks[.ack], marks[.speechStart]].compactMap { $0 }.min().map { Int(($0 * 1000).rounded()) }
    }

    /// One line for the log: the route and the stages in order ("web: routed 2 claudeSpawn 3 … speechStart 7012 ms").
    public var summary: String {
        let stages = Stage.allCases.compactMap { stage in marks[stage].map { "\(stage.rawValue) \(Int(($0 * 1000).rounded()))" } }
        return "\(route?.rawValue ?? "-"): " + stages.joined(separator: " ") + " ms"
    }
}
