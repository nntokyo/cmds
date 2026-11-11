import Foundation

/// Which sessions a command for several of them means (#243).
public enum AssistantScope: Equatable, Sendable {
    /// The workspaces named, as said.
    case named([String])
    /// Every workspace with an agent.
    case all
    /// Those that wait for the user.
    case waiting
    /// Those whose agent is working.
    case working
}

/// Free commands (#243): what the rule grammar did not understand ("api の Claude にログイン画面のテストを書くよう指示して",
/// "tell the api agent to fix the failing test") goes to an interpreter, `claude -p` without any tools, which returns
/// one JSON object. It gets only the utterance and the workspaces' names, agents and states (never screen text), and
/// its result is only a proposal: an `AssistantIntent` that the planner turns into a card the user confirms, like any
/// other command.
public struct AssistantInterpretation: Equatable, Sendable, Decodable {
    public enum Kind: String, Equatable, Sendable, Decodable {
        /// Give agents a task; `text` is the message as the interpreter phrased it.
        case instruct
        /// Send the user's exact words.
        case reply
        /// Option 1 for agents that ask.
        case approve
        /// Go through sessions and report on each.
        case check
        /// Start an agent (`agent`) at the place in `targets` (a workspace or a folder), with `text` as its first task.
        case start
        /// Anything else: a question.
        case question
    }

    public enum Filter: String, Equatable, Sendable, Decodable {
        case named, all, waiting, working
    }

    public var kind: Kind
    public var targets: [String]
    public var filter: Filter
    public var text: String
    public var detailed: Bool
    /// For `start`: "claude" or "codex".
    public var agent: String?

    public init(kind: Kind, targets: [String] = [], filter: Filter = .named, text: String = "", detailed: Bool = false,
                agent: String? = nil) {
        self.kind = kind
        self.targets = targets
        self.filter = filter
        self.text = text
        self.detailed = detailed
        self.agent = agent
    }

    private enum CodingKeys: String, CodingKey { case kind, targets, filter, text, detailed, agent }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .question
        targets = (try? container.decode([String].self, forKey: .targets)) ?? []
        filter = (try? container.decode(Filter.self, forKey: .filter)) ?? .named
        text = (try? container.decode(String.self, forKey: .text)) ?? ""
        detailed = (try? container.decode(Bool.self, forKey: .detailed)) ?? false
        agent = try? container.decode(String.self, forKey: .agent)
    }

    /// The longest message the interpreter may phrase (a spoken instruction is short; anything longer is suspect).
    public static let maxText = 400

    /// The first JSON object in the interpreter's output (it may add a code fence or a word around it); nil when there
    /// is none or it does not decode.
    public static func parse(_ output: String) -> AssistantInterpretation? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONDecoder().decode(AssistantInterpretation.self, from: Data(output[start...end].utf8))
    }

    /// What it means for the planner, or nil for a question (or nothing usable): the caller then answers it as one.
    /// Only workspace names from `world` are kept (a name it made up is dropped); the message is one line, at most
    /// `maxText` characters.
    public func intent(in world: AssistantWorld) -> AssistantIntent? {
        let names = targets.map(AssistantText.trimmed).filter { name in
            guard !AssistantText.key(name).isEmpty else { return false }
            if case .notFound = world.find(name) { return false }
            return true
        }
        let named: AssistantScope? = names.isEmpty ? nil : .named(names)
        let scope: AssistantScope? = switch filter {
        case .all: .all
        case .waiting: .waiting
        case .working: .working
        case .named: named
        }
        let message = AssistantText.oneLine(text)
        switch kind {
        case .question:
            return nil
        case .start:
            // The place may be a folder, not a workspace: it is looked up (and asked about) like a spoken one.
            let kind: AgentKind = (agent ?? "").lowercased().contains("codex") ? .codex : .claude
            let place = targets.map(AssistantText.trimmed).first { !AssistantText.key($0).isEmpty }
            guard message.count <= Self.maxText else { return nil }
            return .startAgent(kind, place: place, task: message.isEmpty ? nil : message)
        case .instruct, .reply:
            guard !message.isEmpty, message.count <= Self.maxText else { return nil }
            switch scope {
            case nil:
                // Nobody named (or only names it made up): the one workspace that waits, as "reply: …" does.
                return targets.isEmpty ? .reply(target: nil, text: message) : nil
            case .named(let list) where list.count == 1:
                return .reply(target: list[0], text: message)
            case let scope?:
                return .replyMany(scope, text: message)
            }
        case .approve:
            switch scope {
            case nil: return targets.isEmpty ? .approve(target: nil) : nil
            case .named(let list) where list.count == 1: return .approve(target: list[0])
            case .named(let list): return .approveMany(.named(list))
            // Approving only means something where an agent asks.
            case .all, .waiting, .working: return .approveMany(.waiting)
            }
        case .check:
            switch scope {
            case .named(let list) where list.count == 1:
                return detailed ? .summary(target: list[0], detailed: true) : .workspaceStatus(target: list[0])
            case let scope?: return .checkAll(scope, detailed: detailed)
            case nil: return targets.isEmpty ? .checkAll(.all, detailed: detailed) : nil
            }
        }
    }

    /// Whether an utterance the rules did not understand may be a command for the agents, worth asking the
    /// interpreter: it names a workspace (also as misheard: EPA for api), speaks of agents, sessions or all of them,
    /// or asks to start, launch or open something. Other questions skip it.
    public static func mightBeCommand(_ utterance: String, world: AssistantWorld) -> Bool {
        guard !AssistantText.key(utterance).isEmpty else { return false }
        if !world.mentioned(in: utterance).isEmpty { return true }
        let folded = AssistantText.folded(AssistantVocabulary.normalizingAgents(utterance))
        return commandWords.contains { folded.contains($0) } || englishCommandWords.occurs(in: folded)
    }

    static let commandWords: [String] = [
        "エージェント", "セッション", "ワークスペース", "ペイン", "クロード", "コーデックス", "codex", "claude", "全部", "すべて",
        "全て", "それぞれ", "指示", "頼んで", "依頼", "伝えて", "させて", "やらせて", "入力待ち",
        "起動", "立ち上げ", "開いて", "始めて", "スタート", "リポジトリ", "フォルダ",
    ].map(AssistantText.folded)

    static let englishCommandWords = Pattern(#"\b(agents?|sessions?|workspaces?|panes?|claude|codex|all of them|every|each|tell|ask|have|make|instruct|let|start|launch|open|run|spin up|fire up|repo|repository|folder)\b"#)

    /// Names in the utterance that are probably a workspace misheard ("EPA" → "api"), for the interpreter.
    public static func misheard(_ utterance: String, world: AssistantWorld) -> [(heard: String, meant: String)] {
        AssistantVocabulary.nameCandidates(in: utterance).compactMap { word in
            guard !world.workspaces.contains(where: { AssistantText.key($0.title) == AssistantText.key(word) }) else { return nil }
            let close = world.soundsLike(word)
            return close.count == 1 ? (word, close[0].title) : nil
        }
    }
}
