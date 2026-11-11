import Foundation

/// What the user asked the assistant (#243), from a command in Japanese or English. Rules first: the commands that
/// act on panes have a fixed grammar, so a free sentence never turns into a send; whatever matches no rule is a
/// question for the on-device model (`question`).
public enum AssistantIntent: Equatable, Sendable {
    /// All workspaces with an agent: who needs the user, who works.
    case status
    /// One workspace: what its agent does or asks ("what is api doing", "apiは何してる").
    case workspaceStatus(target: String)
    /// A summary of a workspace's screen; `detailed` ("in detail", "詳しく") runs `claude -p`.
    case summary(target: String?, detailed: Bool)
    /// Paste `text` into the target's pane and press Return.
    case reply(target: String?, text: String)
    /// Pick the agent's "yes" option (option 1).
    case approve(target: String?)
    /// Pick numbered option `option` (1–9).
    case choose(target: String?, option: Int)
    /// Start Claude Code or Codex in a new workspace at `place` (a workspace name or a folder).
    case startAgent(AgentKind, place: String)
    case pauseListening
    /// Turn the assistant off.
    case stop
    /// "yes" / "はい".
    case confirm
    /// "no" / "いいえ" / "cancel".
    case cancel
    /// Go through every session in `scope` and say what each agent is doing (`detailed`: by `claude -p`).
    case checkAll(AssistantScope, detailed: Bool)
    /// Send `text` to the agents in `scope` (one card for all of them).
    case replyMany(AssistantScope, text: String)
    /// Pick option 1 for the agents in `scope` that ask (one card for all of them).
    case approveMany(AssistantScope)
    /// Anything else.
    case question(String)

    /// Whether carrying it out sends something to a pane or starts a session (always confirmed first).
    public var acts: Bool {
        switch self {
        case .reply, .approve, .choose, .startAgent, .replyMany, .approveMany: return true
        default: return false
        }
    }

    /// The same request aimed at another workspace: the answer to "Which one: api, api-v2?" ("api-v2").
    /// nil for intents without a workspace.
    public func retargeted(_ answer: String) -> AssistantIntent? {
        guard let target = Self.target(answer) else { return nil }
        switch self {
        case .workspaceStatus: return .workspaceStatus(target: target)
        case .summary(_, let detailed): return .summary(target: target, detailed: detailed)
        case .reply(_, let text): return .reply(target: target, text: text)
        case .approve: return .approve(target: target)
        case .choose(_, let option): return .choose(target: target, option: option)
        case .startAgent(let kind, _): return .startAgent(kind, place: target)
        default: return nil
        }
    }

    public static func parse(_ command: String) -> AssistantIntent {
        let text = AssistantText.trimmed(command.precomposedStringWithCompatibilityMapping
            .split(whereSeparator: \.isWhitespace).joined(separator: " "))
        guard !text.isEmpty else { return .question("") }
        for rule in rules {
            guard let groups = rule.pattern.match(text),
                  let intent = rule.make(groups.map { $0.map(AssistantText.trimmed) }) else { continue }
            // "in detail" / "詳しく" asks for the longer summary by `claude -p`.
            if case .summary(let target, _) = intent, detailWords.occurs(in: text) {
                return .summary(target: target, detailed: true)
            }
            if case .checkAll(let scope, _) = intent, detailWords.occurs(in: text) {
                return .checkAll(scope, detailed: true)
            }
            return intent
        }
        return .question(text)
    }

    // MARK: Grammar

    private struct Rule: Sendable {
        let pattern: Pattern
        let make: @Sendable ([String?]) -> AssistantIntent?

        init(_ pattern: String, _ make: @escaping @Sendable ([String?]) -> AssistantIntent?) {
            self.pattern = Pattern(pattern)
            self.make = make
        }
    }

    /// The name of a workspace as said: without "the", "workspace", "ワークスペース" and a trailing particle.
    static func target(_ raw: String?) -> String? {
        guard var value = raw.map(AssistantText.trimmed), !value.isEmpty else { return nil }
        for prefix in ["the workspace ", "workspace ", "the ", "ワークスペース"] where value.lowercased().hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }
        for suffix in [" workspace", "ワークスペース", "のペイン", "のエージェント"] where value.lowercased().hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count))
        }
        while let last = value.last, "のはでにをってがも".contains(last), value.count > 1 { value.removeLast() }
        value = AssistantText.trimmed(value)
        return value.isEmpty ? nil : value
    }

    /// Which sessions "all the waiting ones" / 「入力待ちの」 means.
    private static func scope(_ word: String?) -> AssistantScope {
        let value = AssistantText.folded(word ?? "")
        if ["waiting", "pending"].contains(value) || value.hasPrefix("入力待チ") || value.hasPrefix("待ッテ") { return .waiting }
        if ["working", "busy"].contains(value) || value.hasPrefix("作業中") || value.hasPrefix("動イテ") { return .working }
        return .all
    }

    private static func agent(_ word: String?) -> AgentKind? {
        let value = AssistantText.folded(word ?? "")
        if value.hasPrefix("claude") || value.hasPrefix("クロード") || value.hasPrefix("クラウド") { return .claude }
        if value.hasPrefix("codex") || value.hasPrefix("コーデックス") || value.hasPrefix("コデックス") { return .codex }
        return nil
    }

    private static let detailWords = Pattern("(detail|in depth|thorough|with claude|詳しく|詳細|しっかり|クロードで|claudeで)")

    /// Kanji, kana and digit numbers (`2`, `２`, `二`, `に`) and English number words.
    private static let number = "([1-9１-９一二三四五六七八九]|one|two|three|four|five|six|seven|eight|nine|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth)"

    private static let rules: [Rule] = [
        // Yes / no (also as answers to a confirmation).
        Rule(#"(yes|yeah|yep|yup|sure|ok|okay|do it|go ahead|send it|confirm|confirmed|please do|correct|affirmative)( please)?"#) { _ in .confirm },
        Rule(#"(はい|うん|ええ|オーケー|おけ|いいよ|いいです|お願い|お願いします|送って|送信|実行|実行して|どうぞ|それで|それでお願い|そう|そうです)"#) { _ in .confirm },
        Rule(#"(no|nope|cancel|never ?mind|don't|do not|abort|stop|stop that|forget it)( it| that)?"#) { _ in .cancel },
        Rule(#"(いいえ|いや|いえ|やめて|やめる|やめ|キャンセル|キャンセルして|中止|中止して|取り消し|取り消して|だめ|ダメ|ノー|やっぱりやめて)"#) { _ in .cancel },

        // Listening and the assistant itself.
        Rule(#"(pause|mute)( listening| the mic(rophone)?)?|stop listening( for now)?|go to sleep|be quiet"#) { _ in .pauseListening },
        Rule(#"(聞き取り|リスニング|聞くの|マイク)(を)?(一時停止|止めて|とめて|やめて|オフ)(して)?|一時停止(して)?|静かにして|ちょっと黙って"#) { _ in .pauseListening },
        Rule(#"(turn (yourself )?off|shut ?down|switch off|goodbye|good night|that's all)"#) { _ in .stop },
        Rule(#"(アシスタント|ジャービス)?(を)?(終了|オフ)(して)?|おやすみ|さようなら|もういいよ"#) { _ in .stop },

        // Every session at once: approve all that wait, go through them all.
        Rule(#"(?:approve|accept|allow|say yes to|answer yes to) (?:them all|all(?: of them)?|everything|every (?:one|agent|session)|each (?:one|agent|session)|all (?:the )?(?:waiting|pending)(?: ones| sessions| agents| workspaces)?)|yes to all|approve all(?: waiting)?"#) { _ in
            .approveMany(.waiting)
        },
        Rule(#"(?:(?:入力待ち|待って(?:い)?る|確認待ち)の?(?:もの|セッション|ワークスペース|エージェント|やつ)?(?:に|は)?)?(?:全部|すべて|全て|みんな|全員)(?:に)?(?:はい|イエス|yes|オーケー|ok)(?:と|って)(?:答えて|返して|返事して|言って|送って)(?:ください)?|(?:入力待ち|待って(?:い)?る)の?(?:もの|セッション|ワークスペース|エージェント|やつ)?(?:を)?(?:全部|すべて|全て)(?:を)?(?:承認|許可)(?:して)?(?:ください)?|(?:全部|すべて|全て)(?:を)?(?:承認|許可)(?:して)?(?:ください)?"#) { _ in
            .approveMany(.waiting)
        },
        Rule(#"(?:check|go through|review|summari[sz]e|look at|report on|tell me about)(?: on)? (?:all|every|each)(?: of)?(?: the)?(?: (waiting|working|busy|pending))?(?: (?:sessions?|workspaces?|agents?|ones?))?(?: one by one| in turn| in order)?(?: in detail)?"#) { groups in
            .checkAll(scope(groups[0]), detailed: false)
        },
        Rule(#"(?:check|go through|review|summari[sz]e|look at)(?: on)? (?:the )?(waiting|working|busy|pending) (?:sessions|workspaces|agents|ones)(?: one by one| in turn| in order)?(?: in detail)?"#) { groups in
            .checkAll(scope(groups[0]), detailed: false)
        },
        Rule(#"(?:(入力待ち|待って(?:い)?る|作業中|動いて(?:い)?る)の?)?(?:全部|すべて|全て|各|それぞれ)の?(?:セッション|ワークスペース|エージェント)?(?:を|の)?(?:状況|状態|様子|進捗)?(?:を)?(?:順番に|順に|ひとつずつ|一つずつ|1つずつ)?(?:詳しく)?(?:確認|チェック|見|教え|まとめ|要約|報告)(?:て|して)?(?:ください)?"#) { groups in
            .checkAll(scope(groups[0]), detailed: false)
        },
        Rule(#"(入力待ち|待って(?:い)?る|作業中|動いて(?:い)?る)の?(?:セッション|ワークスペース|エージェント|もの|やつ)(?:を|の)?(?:全部|すべて|全て)?(?:状況を)?(?:順番に|順に|ひとつずつ|一つずつ)?(?:詳しく)?(?:確認|チェック|見|教え|まとめ|要約)(?:て|して)?(?:ください)?"#) { groups in
            .checkAll(scope(groups[0]), detailed: false)
        },

        // Choosing an option.
        Rule(#"(?:choose|pick|select|press)(?: option| number)? \#(number)(?: (?:for|in|on|at) (.+))?"#) { groups in
            AssistantText.number(groups[0] ?? "").map { .choose(target: target(groups[1]), option: $0) }
        },
        Rule(#"option \#(number) (?:for|in|on) (.+)"#) { groups in
            AssistantText.number(groups[0] ?? "").map { .choose(target: target(groups[1]), option: $0) }
        },
        Rule(#"(?:(.+?)(?:で|の|は))?\#(number)番(?:目)?(?:を|で|に)?(?:選んで|選択して|選択|にして|お願い|を押して)?"#) { groups in
            AssistantText.number(groups[1] ?? "").map { .choose(target: target(groups[0]), option: $0) }
        },

        // Approving.
        Rule(#"(?:approve|allow|accept)(?: it| that| the request)?(?: (?:for|in|on|at) (.+)| (.+))?"#) { groups in
            .approve(target: target(groups[0] ?? groups[1]))
        },
        Rule(#"say yes to (.+)"#) { groups in .approve(target: target(groups[0])) },
        Rule(#"(?:(.+?)(?:を|で|の|は))?(?:承認|許可|オーケー)(?:して|する|です)?(?:ください)?"#) { groups in
            .approve(target: target(groups[0]))
        },
        Rule(#"(.+?)に(?:はい|イエス|yes)と(?:答えて|返して|返事して|送って|言って)"#) { groups in .approve(target: target(groups[0])) },

        // Replies.
        Rule(#"(?:reply|answer|respond|say) to (.+?)(?::| with| saying| that) (.+)"#) { groups in
            groups[1].map { .reply(target: target(groups[0]), text: $0) }
        },
        Rule(#"tell (.+?)(?::| to| that) (.+)"#) { groups in
            groups[1].map { .reply(target: target(groups[0]), text: $0) }
        },
        Rule(#"(?:send|type) ["“']?(.+?)["”']? to (.+)"#) { groups in
            groups[0].map { .reply(target: target(groups[1]), text: $0) }
        },
        Rule(#"(?:reply|answer|respond)(?::| with) (.+)"#) { groups in groups[0].map { .reply(target: nil, text: $0) } },
        Rule(#"(.+?)に[「『"“](.+)[」』"”]と?(?:返信|返事|回答|答え|送信|送|伝え|入力)(?:して|て|って)?(?:ください)?"#) { groups in
            groups[1].map { .reply(target: target(groups[0]), text: $0) }
        },
        Rule(#"(.+?)に(.+?)(?:と|って)(?:返信|返事|回答|答え|送信|送|伝え|入力)(?:して|て|って)?(?:ください)?"#) { groups in
            groups[1].map { .reply(target: target(groups[0]), text: $0) }
        },
        Rule(#"[「『"“](.+)[」』"”]と?(?:返信|返事|回答|送信|送)(?:して|って)?"#) { groups in groups[0].map { .reply(target: nil, text: $0) } },

        // Starting a session.
        Rule(#"(?:start|launch|open|run)(?: a)?(?: new)? (claude(?: code)?|codex)(?: session)? (?:in|for|on|at) (.+)"#) { groups in
            guard let kind = agent(groups[0]), let place = target(groups[1]) else { return nil }
            return .startAgent(kind, place: place)
        },
        Rule(#"(.+?)(?:で|に|の)(claude(?: code)?|クロード(?:コード)?|クラウド(?:コード)?|codex|コーデックス|コデックス)を?(?:起動|開始|始めて|立ち上げて|スタート)(?:して)?(?:ください)?"#) { groups in
            guard let kind = agent(groups[1]), let place = target(groups[0]) else { return nil }
            return .startAgent(kind, place: place)
        },

        // Summaries.
        Rule(#"(?:give me )?(?:a )?(?:detailed |full |short |quick )?summary(?: of (.+?))?(?: in detail)?"#) { groups in
            .summary(target: target(groups[0]), detailed: false)
        },
        Rule(#"summari[sz]e(?: (.+?))?(?: in detail| in depth| with claude)?"#) { groups in .summary(target: target(groups[0]), detailed: false) },
        Rule(#"(?:(.+?)(?:を|の))?(?:詳しく|詳細に|簡単に)?(?:要約|まとめ)(?:して|て|を教えて)?(?:ください)?"#) { groups in
            .summary(target: target(groups[0]), detailed: false)
        },

        // One workspace.
        Rule(#"what(?:'s| is| are) (.+?) (?:doing|up to|working on)(?: now| right now)?"#) { groups in
            target(groups[0]).map { .workspaceStatus(target: $0) }
        },
        Rule(#"(?:how(?:'s| is) (.+?)(?: doing| going)?|status of (.+)|check on (.+))"#) { groups in
            target(groups[0] ?? groups[1] ?? groups[2]).map { .workspaceStatus(target: $0) }
        },
        Rule(#"(.+?)(?:は|って|の方は)(?:今|いま)?(?:何|なに|何を|なにを)(?:してる|やってる|している|しています|してますか|してるの)"#) { groups in
            target(groups[0]).map { .workspaceStatus(target: $0) }
        },
        Rule(#"(.+?)の(?:状況|状態|進捗|様子)(?:は|を教えて|はどう|どう)?(?:ですか)?"#) { groups in
            target(groups[0]).flatMap { ["全体", "みんな", "全部", "エージェント"].contains($0) ? nil : .workspaceStatus(target: $0) }
        },

        // Everything.
        Rule(#"(?:(?:give me )?(?:a |the )?status(?: report| update)?|report|what(?:'s| is) (?:going on|happening|up)|how are (?:things|we doing|the agents)(?: going)?|any (?:news|updates))"#) { _ in .status },
        Rule(#"(?:全体の|みんなの|エージェントの)?(?:状況|状態|ステータス|進捗)(?:は|を教えて|を報告して|報告|はどう)?(?:ですか)?|どうなってる|みんな何してる|報告して"#) { _ in .status },
    ]
}
