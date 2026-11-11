import Foundation

/// What speech recognition gets wrong about the assistant's words (#243), and how they are matched anyway.
///
/// - `contextualStrings`: the words the recogniser should expect (the assistant's names, Claude Code, Codex, cmds and
///   the workspaces' titles and agents), handed to SpeechAnalyzer as its context.
/// - `normalizingAgents`: "Claude Code" as it is often heard (クロトコート, クロードコート, cloud code) written as Claude
///   Code, so the rules see it.
/// - `readings` / `distance`: how an ASCII name sounds in Japanese (`api` ⇄ エーピーアイ, read letter by letter or as
///   romaji), so that a name heard in katakana or as other letters (EPA for API) finds the workspace. Only ever used to
///   pick among names that exist; nothing is made up.
public enum AssistantVocabulary {
    // MARK: Recognition context

    /// Words always worth expecting.
    public static let fixedWords = ["Claude", "Claude Code", "クロードコード", "Codex", "cmds"]
    /// The most strings handed to the recogniser.
    public static let maxContextualStrings = 100

    /// The assistant's names, the fixed words, then the workspaces' titles and their agents: each once, at most
    /// `maxContextualStrings`.
    public static func contextualStrings(names: [String], titles: [String], agents: [String] = []) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for word in names + fixedWords + titles + agents {
            let value = word.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !AssistantText.key(value).isEmpty, value.count <= 60, seen.insert(value.lowercased()).inserted else { continue }
            out.append(value)
            if out.count == maxContextualStrings { break }
        }
        return out
    }

    // MARK: Agent names as heard

    /// "Claude Code" and how it is misheard: クロードコード, クロトコート, クロードコート, クラウドコード, cloud code…
    private static let claudeCode = Pattern(
        #"(?:claude|cloud|clawed|claud|クロード|クロド|クロト|クロート|クラウド|くろーど|くろど|くろと|くらうど)\s*(?:code|coat|コード|コート|コド|コト|こーど|こーと)"#)

    /// `text` with every way of hearing "Claude Code" written as "Claude Code". The rest stays as it was.
    public static func normalizingAgents(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return claudeCode.regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "Claude Code ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    // MARK: Readings

    /// How each letter is read in Japanese (A エー, P ピー, I アイ …) and each digit in English.
    static let letterNames: [Character: String] = [
        "a": "エー", "b": "ビー", "c": "シー", "d": "ディー", "e": "イー", "f": "エフ", "g": "ジー", "h": "エイチ",
        "i": "アイ", "j": "ジェー", "k": "ケー", "l": "エル", "m": "エム", "n": "エヌ", "o": "オー", "p": "ピー",
        "q": "キュー", "r": "アール", "s": "エス", "t": "ティー", "u": "ユー", "v": "ブイ", "w": "ダブリュー",
        "x": "エックス", "y": "ワイ", "z": "ゼット",
        "0": "ゼロ", "1": "ワン", "2": "ツー", "3": "スリー", "4": "フォー", "5": "ファイブ", "6": "シックス",
        "7": "セブン", "8": "エイト", "9": "ナイン",
    ]
    /// Vowels heard as their sound rather than their name (EPA for エーピーア…).
    static let vowelSounds: [Character: String] = ["a": "ア", "e": "エ", "i": "イ", "o": "オ", "u": "ウ"]

    /// The longest ASCII run read letter by letter.
    static let maxSpelled = 8
    /// At most this many readings per name.
    static let maxReadings = 32

    /// The ways `name` may be heard, in `sound` form: as written (`key`), and for each ASCII run, read letter by letter,
    /// letter by letter with vowels as sounds, and as romaji in katakana.
    public static func readings(_ name: String) -> Set<String> {
        var result: Set<String> = [sound(AssistantText.key(name))]
        var combined: [String] = [""]
        for run in runs(AssistantText.key(name)) {
            var options: Set<String> = [sound(run)]
            if run.allSatisfy(\.isASCII) {
                if run.count <= maxSpelled {
                    options.insert(sound(run.map { letterNames[$0] ?? String($0) }.joined()))
                    options.insert(sound(run.map { vowelSounds[$0] ?? letterNames[$0] ?? String($0) }.joined()))
                }
                if let kana = run.applyingTransform(.latinToKatakana, reverse: false), kana != run {
                    options.insert(sound(kana))
                }
            }
            combined = Array(combined.flatMap { prefix in options.map { prefix + $0 } }.prefix(maxReadings))
        }
        result.formUnion(combined)
        result.remove("")
        return result
    }

    /// Runs of ASCII letters and digits, and runs of everything else.
    static func runs(_ key: String) -> [String] {
        var out: [String] = []
        var current = ""
        var currentASCII: Bool?
        for character in key {
            let ascii = character.isASCII && (character.isLetter || character.isNumber)
            if currentASCII != nil, currentASCII != ascii {
                out.append(current)
                current = ""
            }
            current.append(character)
            currentASCII = ascii
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Katakana with small kana as large, ヱ / ヰ / ヲ as エ / イ / オ, ヅ / ヂ as ズ / ジ and no ッ or ー: how close two
    /// readings sound.
    static func sound(_ text: String) -> String {
        let map: [Character: String] = [
            "ァ": "ア", "ィ": "イ", "ゥ": "ウ", "ェ": "エ", "ォ": "オ", "ャ": "ヤ", "ュ": "ユ", "ョ": "ヨ", "ヮ": "ワ",
            "ヱ": "エ", "ヰ": "イ", "ヲ": "オ", "ヅ": "ズ", "ヂ": "ジ", "ッ": "", "ー": "",
        ]
        return String(text.flatMap { map[$0] ?? String($0) })
    }

    /// The edit distance between two strings, in characters.
    public static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// How far `said` sounds from `name`: the closest pair of their readings; nil when they are too far apart to be
    /// the same name misheard (one character off for 3–5 characters, two from 6; never for shorter names, which only
    /// match when they sound the same).
    public static func soundDistance(_ said: String, _ name: String) -> Int? {
        let saidReadings = readings(said)
        let nameReadings = readings(name)
        var best: Int?
        for a in saidReadings {
            for b in nameReadings {
                let d = distance(a, b)
                let shorter = min(a.count, b.count)
                let allowed = shorter >= 6 ? 2 : shorter >= 3 ? 1 : 0
                guard d <= allowed else { continue }
                if best.map({ d < $0 }) ?? true { best = d }
            }
        }
        return best
    }

    /// Words in an utterance that may be names as heard: ASCII words of two or more characters and katakana runs of
    /// three or more.
    public static func nameCandidates(in utterance: String) -> [String] {
        let text = utterance.precomposedStringWithCompatibilityMapping
        var out: [String] = []
        var current = ""
        var kind = 0  // 1 ASCII, 2 katakana
        func flush() {
            if (kind == 1 && current.count >= 2) || (kind == 2 && current.count >= 3) { out.append(current) }
            current = ""
            kind = 0
        }
        for character in text {
            let next: Int
            if character.isASCII && (character.isLetter || character.isNumber) {
                next = 1
            } else if character.unicodeScalars.allSatisfy({ (0x30A1...0x30FA).contains($0.value) || $0.value == 0x30FC }) {
                next = 2
            } else {
                next = 0
            }
            if next != kind { flush() }
            if next != 0 {
                current.append(character)
                kind = next
            }
        }
        flush()
        return out
    }
}
