import Foundation

/// What the on-device model's answer means beyond its words (#243): an action it was asked for (it answers
/// `actionMarker`, or apologises that it cannot: 「申し訳ありませんが、アプリの起動はできません」). Such an answer is never
/// spoken; the request goes to the interpreter instead, else the assistant says how to ask.
public enum AssistantModelReply {
    /// What the on-device model answers, alone, when it was asked to do something. Never spoken.
    public static let actionMarker = "[[ACTION]]"

    /// The marker (also half-broken), or an apology / refusal to act.
    public static func isAction(_ answer: String) -> Bool {
        let text = AssistantText.folded(answer)
        if text.contains("[[action") || text.contains("action]]") || text.trimmingCharacters(in: markerCharacters) == "action" { return true }
        return refusals.contains { $0.occurs(in: text) }
    }

    /// What may surround a marker the model half-broke ("[ACTION]", "ACTION.").
    static let markerCharacters = CharacterSet(charactersIn: "[] .。")

    /// Whether the on-device model's one-sentence summary of a session can be said: not empty, no action marker or
    /// refusal, and not a bracketed word alone ("[START]"). Otherwise the facts are said instead.
    public static func isSummary(_ text: String) -> Bool {
        let bare = text.trimmingCharacters(in: markerCharacters)
        return !(text.isEmpty || isAction(text) || (text.hasPrefix("[") && !bare.contains(" ")))
    }

    /// 「申し訳ありませんが…できません」, "I'm sorry, I can't…", "I am unable to…" (the Japanese folded like the answer).
    static let refusals: [Pattern] = [
        Pattern(AssistantText.folded(#"(申し訳(ありません|ございません|ない)|すみません|ごめんなさい)[^。]{0,40}(できません|できない|出来ません|いたしかねます)"#)),
        Pattern(AssistantText.folded(#"(起動|実行|操作|開く|開始|送信|承認|立ち上げ)[^。]{0,12}(できません|できない|出来ません)"#)),
        Pattern(#"\b(i can't|i cannot|i can not|i'm unable to|i am unable to|i'm not able to|i am not able to)\b[^.]{0,30}\b(start|launch|open|run|execute|perform|do that|do this|send|approve|control|operate)\b"#),
    ]
}
