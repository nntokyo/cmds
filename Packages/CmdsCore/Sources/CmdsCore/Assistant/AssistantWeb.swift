import Foundation

/// Which free questions go to Claude Code with web search instead of the on-device model (#243). The on-device model
/// has no internet: a question about the weather, the news or prices, or one where the user asks to search, goes to
/// `claude -p` with only WebSearch and WebFetch (Settings › Assistant › "Use Claude for web questions"). A question that
/// looks local first goes to the on-device model, which answers `marker` when it needs current or outside
/// information; then it goes to Claude as well.
public enum AssistantWeb {
    /// What the on-device model answers, alone, when the question needs current or outside information. Never spoken.
    public static let marker = "[[NEEDS_WEB]]"

    /// Whether the question should go to Claude with web search at once: the user asks to search or to ask Claude, or
    /// it is about something live (weather, news, prices, rates, traffic, scores, "today's", "latest").
    public static func needsWeb(_ question: String) -> Bool {
        let text = AssistantText.folded(question)
        guard !text.isEmpty else { return false }
        if japaneseWords.contains(where: { text.contains($0) }) { return true }
        return englishPatterns.contains { $0.occurs(in: text) }
    }

    /// Whether the on-device model's answer says it needs the web: the marker (also half-broken, as `[NEEDS_WEB]` or
    /// `NEEDS_WEB`), or a plain "I can't search the internet / have no real-time information".
    public static func answerNeedsWeb(_ answer: String) -> Bool {
        let text = AssistantText.folded(answer)
        if text.contains("needs_web") || text.contains("needs web") { return true }
        return cannotKnow.contains { $0.occurs(in: text) }
    }

    /// The answer without the marker (it is never spoken, also when the setting is off).
    public static func withoutMarker(_ answer: String) -> String {
        answer.replacingOccurrences(of: #"\[*\s*needs[_ ]web\s*\]*"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Claude's answer made fit to speak: without a trailing "Sources:" list, Markdown links (their text stays), bare
    /// URLs, emphasis and heading marks, and line breaks.
    public static func speakable(_ answer: String) -> String {
        var lines: [String] = []
        for line in answer.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if lower.hasPrefix("sources:") || lower.hasPrefix("source:") || lower.hasPrefix("**sources")
                || trimmed.hasPrefix("出典") || trimmed.hasPrefix("情報源") || trimmed.hasPrefix("参考:") || trimmed.hasPrefix("参考：") {
                break
            }
            lines.append(trimmed.replacingOccurrences(of: #"^(#+|[-*•]|\d+[.)])\s+"#, with: "", options: .regularExpression))
        }
        var text = lines.filter { !$0.isEmpty }.joined(separator: " ")
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\((?:https?://)[^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\(?https?://[^\s)）]+\)?"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(\*\*|__|`)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Words

    /// Japanese words, folded as `AssistantText.folded` does (hiragana as katakana) so both kana spellings match.
    static let japaneseWords: [String] = [
        // Asked to search or to ask Claude.
        "検索", "調べて", "調べる", "調べてきて", "ググ", "ネットで", "ネット検索", "インターネット", "ウェブで", "webで",
        "クロードに聞", "クロードにきい", "クロードに質問", "claudeに聞", "claudeにきい", "claudeに質問", "クラウドに聞",
        // Live information.
        "天気", "気温", "予報", "降水", "雨降", "雨が降", "台風", "地震", "ニュース", "株価", "日経平均", "ダウ平均", "為替",
        "円安", "円高", "ドル円", "円相場", "レート", "仮想通貨", "ビットコイン", "今日の", "きょうの", "最新", "運行", "遅延",
        "電車", "運休", "渋滞", "交通情報", "試合", "スコア", "選挙", "営業時間", "開店", "閉店",
    ].map(AssistantText.folded)

    static let englishPatterns: [Pattern] = [
        // Asked to search or to ask Claude.
        Pattern(#"^(please )?search\b|\bsearch (the )?(web|internet|online)\b|\bweb search\b|\blook (it |that |this )?up\b|\bgoogl(e|ing)\b|\bon(line| the (web|internet))\b|\binternet\b|\b(ask|use|with) claude\b"#),
        // Live information.
        Pattern(#"\b(weather|forecast|temperature|raining|rain (today|tomorrow)|snow(ing)?|typhoon|earthquake|news|headlines?|stocks?|share price|stock price|nasdaq|nikkei|dow jones|s&p|exchange rate|dollar to|to yen|bitcoin|crypto|today[’']s|tonight[’']s|tomorrow[’']s|this week[’']s|latest|traffic|train (status|delays?)|scores|score of|who won|election|opening hours|open now)\b"#),
    ]

    /// "I can't search the internet", "リアルタイムの情報にはアクセスできません" (the Japanese one folded like the answer).
    static let cannotKnow: [Pattern] = [
        Pattern(AssistantText.folded(#"(インターネット|ネット|ウェブ|web|リアルタイム|最新の情報|最新情報|現在の情報)[^。]{0,24}(できません|できない|ありません|持っていません|わかりません|分かりません)"#)),
        Pattern(#"\b(can't|cannot|can not|don't|do not|unable to)\b[^.]{0,40}\b(internet|browse|search the web|real-time|realtime|live data|current information|up-to-date)\b"#),
        Pattern(#"\b(no|without) (access to )?(the )?(internet|real-time|realtime|live) (access|data|information)?"#),
    ]
}
