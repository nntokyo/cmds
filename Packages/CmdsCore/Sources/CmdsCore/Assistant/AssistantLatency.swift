import Foundation

/// Which way a free question goes (#248), decided by the rules so the interpreter's round trip (`claude -p`, about
/// 1.5–2.5 s) is spent only where it can change the outcome.
public enum AssistantRoute: Equatable, Sendable {
    /// Claude with web search at once.
    case web
    /// The on-device model (which may still hand it to the web or the interpreter).
    case model
    /// The interpreter first, then (a question after all) the answer: a command for sure.
    case interpreter
    /// The interpreter and the on-device model at the same time: the interpreter's verdict decides, the model's answer
    /// is ready when it says it is a question.
    case interpreterAndModel

    /// - Not a possible command (`AssistantInterpretation.mightBeCommand`) or the interpreter is off: as before, the web
    ///   for live information, else the model.
    /// - A request to an agent (指示して, させて, もらって, tell, have, start…): the interpreter, as before.
    /// - A live-information question that names no workspace ("Claude Codeの最新バージョンは？"): the web, without the
    ///   interpreter (it would only say "question").
    /// - Otherwise (it names a workspace or speaks of sessions, but asks rather than orders): both at once.
    public static func decide(_ question: String, world: AssistantWorld, web: Bool, interpreter: Bool) -> AssistantRoute {
        let live = web && AssistantWeb.needsWeb(question)
        guard interpreter, AssistantInterpretation.mightBeCommand(question, world: world) else { return live ? .web : .model }
        if isRequest(question) { return .interpreter }
        if live, world.mentioned(in: question).isEmpty { return .web }
        return .interpreterAndModel
    }

    /// Whether the utterance asks for something to be done (an order to an agent or the app), not for information.
    static func isRequest(_ question: String) -> Bool {
        let folded = AssistantText.folded(AssistantVocabulary.normalizingAgents(question))
        return requestWords.contains { folded.contains($0) } || englishRequest.occurs(in: folded)
    }

    static let requestWords: [String] = [
        "指示", "頼んで", "頼む", "依頼", "伝えて", "させて", "やらせて", "もらって", "もらえ", "おいて", "起動", "立ち上げ",
        "開いて", "始めて", "スタート", "承認", "許可して", "送って", "送信", "書いて", "直して", "修正して", "実行して",
        "走らせ", "止めて", "中断",
    ].map(AssistantText.folded)

    static let englishRequest = Pattern(#"\b(tell|ask|have|make|instruct|let|start|launch|open|run|spin up|fire up|approve|send|reply|answer|fix|write|stop|cancel|continue)\b"#)
}

/// The short acknowledgement for a slow answer (#248): 「調べます。」 / "Checking." once Claude has been at it for
/// `delay` without an answer, so the user hears at once that the question was taken. Never for a fast answer, never
/// over the assistant's own voice, never twice.
public enum AssistantAck {
    /// How long a slow answer may take before the acknowledgement.
    public static let delay: TimeInterval = 0.8

    /// Whether to say it now: a slow path (`claude -p` for the answer), still thinking about the same request, nothing
    /// said for it yet and the voice free.
    public static func due(slow: Bool, elapsed: TimeInterval, thinking: Bool, said: Bool, voiceActive: Bool) -> Bool {
        slow && elapsed >= delay && thinking && !said && !voiceActive
    }
}

/// Web answers kept for a while (#248): the same question again ("明日の東京の天気は？" twice, or after a follow-up) is
/// answered at once instead of searching again. Keyed by the question as `AssistantText.key` folds it, the language
/// and the local day (so "today" and "tomorrow" never cross midnight); only answers, never failures; at most
/// `capacity`, the oldest dropped.
public struct AssistantWebCache: Equatable, Sendable {
    /// How long an answer is reused.
    public static let lifetime: TimeInterval = 600
    public static let capacity = 20

    private struct Entry: Equatable, Sendable {
        var key: String
        var answer: String
        var at: Date
    }

    private var entries: [Entry] = []

    public init() {}

    public static func key(_ question: String, language: String, now: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: now)
        return "\(language)|\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)|\(AssistantText.key(question))"
    }

    /// The answer to the same question within `lifetime`, if any.
    public func answer(_ question: String, language: String, now: Date, timeZone: TimeZone = .current) -> String? {
        let key = Self.key(question, language: language, now: now, timeZone: timeZone)
        return entries.last { $0.key == key && now.timeIntervalSince($0.at) < Self.lifetime && now >= $0.at }?.answer
    }

    public mutating func store(_ answer: String, for question: String, language: String, now: Date, timeZone: TimeZone = .current) {
        let key = Self.key(question, language: language, now: now, timeZone: timeZone)
        guard !AssistantText.key(question).isEmpty, !answer.isEmpty else { return }
        entries.removeAll { $0.key == key || now.timeIntervalSince($0.at) >= Self.lifetime }
        entries.append(Entry(key: key, answer: answer, at: now))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }
}
