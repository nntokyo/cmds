import Foundation

/// The sentences the assistant says and shows (#243). Like `AgentFormat.Strings`, CmdsCore has no String Catalog:
/// `.english` is built in (tests), the app passes `.localized` from its catalog (Japanese and English, following the
/// app's language, which is also the language speech is recognised and spoken in).
public enum AssistantLine: Equatable, Sendable {
    // Status.
    case noAgents
    /// "2 need you, 1 working." (counts of 0 are left out by the caller: `needYou` and `working` are both > 0 or one is).
    case overview(needYou: Int, working: Int)
    case allQuiet(count: Int)
    case needsYou(workspace: String)
    case asks(String)
    case working(workspace: String)
    case workingOn(workspace: String, topic: String)
    case done(workspace: String)
    case idle(workspace: String)
    case stopped(workspace: String)
    case noAgentIn(workspace: String)
    case agentIn(agent: String, workspace: String)
    case waitedMinutes(Int)
    case optionsOffered(count: Int, first: String)
    // Finding the target.
    case notFound(String)
    case whichWorkspace([String])
    case nobodyWaiting
    case unclearPane(workspace: String, panes: [String])
    case noQuestion(workspace: String)
    case noSuchOption(workspace: String, number: Int)
    case unknownPlace(String)
    // Confirming.
    case confirmReply(text: String, workspace: String)
    case confirmChoice(number: Int, label: String, workspace: String)
    case confirmStart(agent: String, place: String)
    case sayYesOrPressReturn
    case pressReturnToConfirm
    case voiceNotEnough
    case sent(workspace: String)
    case started(agent: String, place: String)
    case failed
    case cancelled
    case expired
    case nothingToConfirm
    // The assistant itself.
    case wake
    case paused
    case goodbye
    case modelUnavailable

    public var english: String {
        switch self {
        case .noAgents: return "No agents are running."
        case .overview(let needYou, let working):
            switch (needYou, working) {
            case (0, _): return "\(working) working."
            case (_, 0): return needYou == 1 ? "1 needs you." : "\(needYou) need you."
            default: return (needYou == 1 ? "1 needs you, " : "\(needYou) need you, ") + "\(working) working."
            }
        case .allQuiet(let count): return count == 1 ? "1 agent, nothing needs you." : "\(count) agents, nothing needs you."
        case .needsYou(let workspace): return "\(workspace) needs you."
        case .asks(let question): return "It asks: \(question)"
        case .working(let workspace): return "\(workspace) is working."
        case .workingOn(let workspace, let topic): return "\(workspace) is working on \(topic)."
        case .done(let workspace): return "\(workspace) is done."
        case .idle(let workspace): return "\(workspace) is idle."
        case .stopped(let workspace): return "\(workspace) has stopped."
        case .noAgentIn(let workspace): return "No agent is running in \(workspace)."
        case .agentIn(let agent, let workspace): return "\(agent) in \(workspace)."
        case .waitedMinutes(let minutes): return minutes == 1 ? "Waiting for 1 minute." : "Waiting for \(minutes) minutes."
        case .optionsOffered(let count, let first): return "\(count) options, the first is \(first)."
        case .notFound(let name): return "I can't find a workspace called \(name)."
        case .whichWorkspace(let titles): return "Which one: \(titles.joined(separator: ", "))?"
        case .nobodyWaiting: return "No workspace is waiting for you. Which one do you mean?"
        case .unclearPane(let workspace, let panes):
            return "\(workspace) has several panes (\(panes.joined(separator: ", "))). Please use the reply panel."
        case .noQuestion(let workspace): return "\(workspace) isn't asking anything."
        case .noSuchOption(let workspace, let number): return "\(workspace) has no option \(number)."
        case .unknownPlace(let name): return "I don't know a workspace or folder called \(name)."
        case .confirmReply(let text, let workspace): return "Send “\(text)” to \(workspace)?"
        case .confirmChoice(let number, let label, let workspace): return "Choose \(number), “\(label)”, in \(workspace)?"
        case .confirmStart(let agent, let place): return "Start \(agent) in \(place)?"
        case .sayYesOrPressReturn: return "Say yes or press Return."
        case .pressReturnToConfirm: return "This one needs Return or a click."
        case .voiceNotEnough: return "Please press Return or click the button for this one."
        case .sent(let workspace): return "Sent to \(workspace)."
        case .started(let agent, let place): return "Started \(agent) in \(place)."
        case .failed: return "That didn't work: the pane is gone or busy."
        case .cancelled: return "Cancelled."
        case .expired: return "I cancelled it: no answer."
        case .nothingToConfirm: return "There is nothing to confirm."
        case .wake: return "Yes?"
        case .paused: return "Listening paused."
        case .goodbye: return "Assistant off."
        case .modelUnavailable: return "I can only answer about the workspaces: the on-device model isn't available."
        }
    }
}

public struct AssistantStrings: Sendable {
    public var text: @Sendable (AssistantLine) -> String
    /// Between sentences: a space in English, nothing in Japanese.
    public var separator: String

    public init(separator: String, text: @escaping @Sendable (AssistantLine) -> String) {
        self.separator = separator
        self.text = text
    }

    public static let english = AssistantStrings(separator: " ") { $0.english }

    public func callAsFunction(_ line: AssistantLine) -> String { text(line) }

    public func join(_ lines: [AssistantLine]) -> String { lines.map(text).joined(separator: separator) }
}

/// The spoken status (#243): the whole picture, or one workspace.
public enum AssistantReport {
    /// Workspaces shown by name at most; the rest only count.
    static let maxNamed = 4

    /// "2 need you, 1 working. api needs you. It asks: Run the tests? web is working on Add login."
    public static func status(_ world: AssistantWorld, strings: AssistantStrings) -> String {
        let agents = world.withAgents
        guard !agents.isEmpty else { return strings(.noAgents) }
        let needYou = agents.count { $0.state == .needsUser }
        let working = agents.count { $0.state == .working }
        var lines: [AssistantLine] = needYou + working == 0 ? [.allQuiet(count: agents.count)]
            : [.overview(needYou: needYou, working: working)]
        for workspace in agents.prefix(maxNamed) where workspace.state == .needsUser || workspace.state == .working {
            lines += stateLines(workspace, withQuestion: workspace.state == .needsUser)
        }
        return strings.join(lines)
    }

    /// "api: Claude. api needs you. It asks: Run the tests? 3 options, the first is Yes. Waiting for 4 minutes."
    public static func workspace(_ workspace: AssistantWorld.Workspace, now: Date, strings: AssistantStrings) -> String {
        guard workspace.state != nil else { return strings(.noAgentIn(workspace: workspace.title)) }
        var lines: [AssistantLine] = []
        if let agent = workspace.agent { lines.append(.agentIn(agent: agent, workspace: workspace.title)) }
        lines += stateLines(workspace, withQuestion: true)
        if workspace.state == .needsUser {
            if let prompt = workspace.panes.compactMap(\.prompt).first, let first = prompt.options.first {
                lines.append(.optionsOffered(count: prompt.options.count, first: first.label))
            }
            if let since = workspace.waitingSince {
                let minutes = Int(now.timeIntervalSince(since) / 60)
                if minutes >= 1 { lines.append(.waitedMinutes(minutes)) }
            }
        }
        return strings.join(lines)
    }

    private static func stateLines(_ workspace: AssistantWorld.Workspace, withQuestion: Bool) -> [AssistantLine] {
        let title = workspace.title
        switch workspace.state {
        case .needsUser:
            let question = workspace.panes.compactMap { $0.prompt?.question }.first ?? workspace.notification
            if withQuestion, let question = question.map(clip), !question.isEmpty {
                return [.needsYou(workspace: title), .asks(question)]
            }
            return [.needsYou(workspace: title)]
        case .working:
            if let topic = workspace.topic.map(clip), !topic.isEmpty { return [.workingOn(workspace: title, topic: topic)] }
            return [.working(workspace: title)]
        case .done: return [.done(workspace: title)]
        case .idle: return [.idle(workspace: title)]
        case .stopped: return [.stopped(workspace: title)]
        case nil: return [.noAgentIn(workspace: title)]
        }
    }

    /// Long titles and questions are cut for speech.
    static func clip(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > 120 ? String(flat.prefix(119)) + "…" : flat
    }
}
