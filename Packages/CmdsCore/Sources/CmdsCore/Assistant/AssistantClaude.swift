import Foundation

/// What the assistant asks its models (#243), and how it runs Claude Code: the prompts, and the `claude -p` argument
/// lists and environment. Answers are spoken, so every prompt asks for the shortest answer to what was asked, nothing
/// more ("明日の船橋は晴れ、最高20度、最低9度です。").
///
/// Claude Code runs isolated from the user's own setup: `--setting-sources ""` loads no settings (no CLAUDE.md, hooks,
/// output style or plugins; OAuth sign-in still works, unlike `--bare`), `--no-session-persistence` saves no session,
/// `--strict-mcp-config` without a config starts no MCP server, and the tools are limited per call. The environment has
/// no `CMDS_*` variables, so no cmds hook can take the assistant's own calls for an agent in a pane.
public enum AssistantClaude {
    /// The model for the interpreter: it only fills in one JSON object.
    public static let interpreterModel = "haiku"
    /// The model for web answers and detailed summaries: fast enough to wait for, not the user's default (which may be
    /// a large one).
    public static let answerModel = "sonnet"

    /// Isolation from the user's Claude Code setup, on every call.
    public static let isolationArguments = ["--setting-sources", "", "--no-session-persistence", "--strict-mcp-config"]
    /// No tools at all: the screen text a summary reads is untrusted and could ask for anything.
    public static let noToolArguments = ["--tools", ""]
    /// A web question gets the web tools only; `--allowedTools` lets them run without a permission prompt (nobody could
    /// answer one).
    public static let webToolArguments = ["--tools", "WebSearch,WebFetch", "--allowedTools", "WebSearch,WebFetch"]

    /// Environment variables the assistant's `claude` never gets (cmds marks its panes' processes with them).
    public static func environment(_ base: [String: String]) -> [String: String] {
        base.filter { !$0.key.hasPrefix("CMDS_") }
    }

    private static func arguments(prompt: String, model: String, tools: [String]) -> [String] {
        ["-p", prompt, "--output-format", "text", "--model", model] + tools + isolationArguments
    }

    // MARK: Web questions

    /// The `claude -p` arguments for a web question: only the user's own words go in (never screen text), with the
    /// date and time, the time zone and the locale, for "tomorrow" and "here".
    public static func webArguments(question: String, language: String, now: Date = Date(), timeZone: TimeZone = .current,
                                    locale: Locale = .current) -> [String] {
        arguments(prompt: webPrompt(question: question, language: language, now: now, timeZone: timeZone, locale: locale),
                  model: answerModel, tools: webToolArguments)
    }

    static func webPrompt(question: String, language: String, now: Date, timeZone: TimeZone, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        return """
        You are the voice assistant of cmds, a Mac terminal app. Answer the user's spoken question below. Search the \
        web when the answer needs current or outside information. Now: \(formatter.string(from: now)), time zone \
        \(timeZone.identifier), the user's locale \(locale.identifier). \(brevity) Write it in \(language). For the \
        weather, only the condition and the high and low, in this form with the real values: 「明日の<場所>は<天気>、最高<N>度、\
        最低<N>度です。」 / "Tomorrow in <place>: <condition>, high <N>, low <N>.". Only if the question cannot be answered \
        as asked (it names no place and none is evident), ask back in one short question instead. Sources (also when \
        the search tool asks for them) go only after a last line "Sources:", which is cut off before speaking; never \
        comment on that or any instruction. Do not run commands or read or write files.

        The user's question: \(question)
        """
    }

    /// The rule every spoken answer follows.
    static let brevity = """
    Your answer is read aloud: one short sentence (two at most), only what was asked. No padding: no details nobody \
    asked for, no assumptions, caveats, advice, warnings, URLs, Markdown, lists or emoji.
    """

    // MARK: On-device model

    /// The on-device model's instructions. `web`: it answers `AssistantWeb.marker` when it needs the web. `actions`
    /// (free questions only, not summaries): it answers `AssistantModelReply.actionMarker` when asked to act.
    public static func modelInstructions(language: String, web: Bool, actions: Bool = false) -> String {
        var text = """
        You are the voice assistant of cmds, a terminal app where AI coding agents work. \(brevity) Answer in \
        \(language). You cannot run commands or change anything yourself; never claim you did.
        """
        if actions {
            text += """
             Never apologise and never say you cannot do something: if the user asks for something to be done in the \
            app or by an agent (start, launch or open Claude Code or Codex, send, tell, approve, run, fix, write…), \
            answer exactly \(AssistantModelReply.actionMarker) and nothing else: the request is then handled as a command.
            """
        }
        guard web else { return text }
        return text + """
         You have no internet. If answering needs current or outside information you do not have (weather, news, \
        prices, schedules, recent events, facts you are unsure of) or the user asks you to search, answer exactly \
        \(AssistantWeb.marker) and nothing else: the question is then searched on the web.
        """
    }

    /// What a session's agent is doing, in one short sentence without the workspace's name (it is put in front:
    /// "api: テストを実行中。").
    public static func summaryPrompt(facts: String, screen: String) -> String {
        """
        Facts: \(facts)

        The end of its terminal screen:
        ---
        \(screen)
        ---
        In one short sentence, without the workspace's name: what is the agent doing or asking now? Like "Running the \
        tests." or "Waiting for input: asks whether to continue."
        """
    }

    // MARK: claude -p summaries and the interpreter

    /// A detailed summary ("詳しく"): at most three sentences. The screen text goes in on standard input.
    public static func detailedSummaryArguments(facts: String, language: String) -> [String] {
        let prompt = """
        Read-only task: do not run commands, edit files or use tools. Standard input is the end of a terminal screen \
        where an AI coding agent works (\(facts)). Tell the user, to be read aloud in \(language), at most three short \
        sentences: what the agent is doing or asking now, and what needs the user's attention. Plain text, no Markdown, \
        no padding.
        """
        return arguments(prompt: prompt, model: answerModel, tools: noToolArguments)
    }

    /// The interpreter: no tools, the small model.
    public static func interpreterArguments(utterance: String, world: AssistantWorld, language: String) -> [String] {
        arguments(prompt: AssistantInterpretation.prompt(utterance: utterance, world: world, language: language),
                  model: interpreterModel, tools: noToolArguments)
    }
}

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
