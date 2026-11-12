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
