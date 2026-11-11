import Foundation

/// Starting an agent with a task by voice (#243): the task as said turned into a request to the agent
/// (「ログイン画面のテストを書かせて」 → 「ログイン画面のテストを書いてください」, "have it fix the failing tests" → "Fix the
/// failing tests."), and the command line the new workspace runs (`claude '<task>'`). The task is always one
/// single-quoted word: nothing in it is ever read by the shell.
public enum AssistantLaunch {
    /// The longest task passed to a new agent.
    public static let maxTask = 400

    /// The command line for a new workspace: the agent (`claude` / `codex`, or `executable` when given), and the task as
    /// its first prompt, single-quoted. No other arguments (never a permission-skipping flag).
    public static func command(_ kind: AgentKind, task: String?, executable: String? = nil) -> String {
        let program = executable.map(quote) ?? (kind == .codex ? "codex" : "claude")
        guard let task = task.flatMap(cleaned) else { return program }
        return program + " " + quote(task)
    }

    /// POSIX single quotes: the text stays literal in sh, bash and zsh (`'` becomes `'\''`).
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The task as one line: control characters (newlines) as spaces, spaces collapsed, no leading dashes (it must not
    /// read as an option), at most `maxTask` characters; nil when nothing is left.
    public static func cleaned(_ task: String) -> String? {
        let flat = String(task.unicodeScalars.map { scalar -> Character in
            scalar.value < 0x20 || scalar.value == 0x7F || (0x80..<0xA0).contains(scalar.value) ? " " : Character(scalar)
        })
        var value = flat.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let first = value.first, first == "-" || first == "—" || first == " " { value.removeFirst() }
        value = String(value.prefix(maxTask)).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    // MARK: The task as said

    /// The request to an agent in a clause like 「テストを書かせて」, 「バグを直すように指示して」, 「テストを書いて」
    /// (`plainRequest`: also a plain request, after "start Claude, …") or "have it fix the tests"; nil when the
    /// clause is no task.
    public static func request(_ clause: String, plainRequest: Bool = false) -> String? {
        let text = AssistantText.trimmed(clause)
        guard !text.isEmpty else { return nil }
        if let groups = english.match(text), let body = groups[0].map(AssistantText.trimmed), !body.isEmpty {
            return sentence(body)
        }
        // 「書かせて」: the causative of a verb, as a request.
        if let groups = causative.match(text), let body = groups[0], let ending = groups[1], let te = causativeTe[ending] {
            return body + te + "ください"
        }
        // 「直すように指示して」「修正するよう伝えて」.
        if let groups = askTo.match(text), let body = groups[0].map(AssistantText.trimmed), !body.isEmpty {
            return teForm(body).map { $0 + "ください" } ?? body + "ようお願いします"
        }
        if plainRequest, let groups = plain.match(text), let body = groups[0], !body.isEmpty, body.count > 2 {
            return body + "ください"
        }
        return nil
    }

    private static let english = Pattern(#"(?:and |then |, )*(?:have|let|get|make|tell|ask) (?:it|him|her|them|claude(?: code)?|codex)(?: to)? (.+?)\.?"#)
    private static let causative = Pattern(#"(.+?)(か|が|さ|た|ら|わ|ま|ば|な)せて(?:ください|くれ|おいて|ね)?"#)
    private static let causativeTe: [String: String] = [
        "か": "いて", "が": "いで", "さ": "して", "た": "って", "ら": "って", "わ": "って", "ま": "んで", "ば": "んで", "な": "んで",
    ]
    private static let askTo = Pattern(#"(.+?)(?:よう(?:に)?)(?:指示|依頼|お願い|伝え|言っ|頼ん)(?:して|て|で)?(?:ください|おいて)?"#)
    private static let plain = Pattern(#"(.+?(?:て|で))(?:ください|くれ|ね)?"#)

    /// The te-form of a verb in its dictionary form (「書く」→「書いて」, 「修正する」→「修正して」, 「調べる」→「調べて」);
    /// nil when the text does not end in one.
    static func teForm(_ text: String) -> String? {
        if text.hasSuffix("する") { return String(text.dropLast(2)) + "して" }
        if text.hasSuffix("行く") { return String(text.dropLast()) + "って" }
        guard let last = text.last else { return nil }
        let stem = String(text.dropLast())
        switch last {
        case "く": return stem + "いて"
        case "ぐ": return stem + "いで"
        case "す": return stem + "して"
        case "つ", "う": return stem + "って"
        case "む", "ぶ", "ぬ": return stem + "んで"
        case "る":
            // 調べる, 見る (e / i row before る): ichidan; else godan (作る → 作って).
            if let before = stem.last, "えけげせぜてでねへべぺめれいきぎしじちぢにひびぴみり".contains(before) { return stem + "て" }
            return stem + "って"
        default: return nil
        }
    }

    /// "fix the failing tests" → "Fix the failing tests."
    private static func sentence(_ text: String) -> String {
        var value = text
        if let first = value.first, first.isLowercase { value.replaceSubrange(value.startIndex...value.startIndex, with: first.uppercased()) }
        if let last = value.last, !".!?。！？".contains(last) { value.append(".") }
        return value
    }
}
