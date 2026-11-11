import Foundation

/// The sentences the assistant says and shows (#243). Like `AgentFormat.Strings`, CmdsCore has no String Catalog:
/// `.english` is built in (tests), the app passes `.localized` from its catalog (Japanese and English, following the
/// app's language, which is also the language speech is recognised and spoken in).
public enum AssistantLine: Equatable, Sendable {
    // Status.
    case noAgents
    /// "2 waiting: api, api-v2." (the names as one list, cut after a few).
    case waitingList(count: Int, names: String)
    /// "1 working: web."
    case workingList(count: Int, names: String)
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
    /// No place said (or none found) for a start.
    case whereToStart
    /// Several project folders fit (at most three, shortened).
    case whichFolder([String])
    // Confirming.
    case confirmReply(text: String, workspace: String)
    case confirmChoice(number: Int, label: String, workspace: String)
    case confirmStart(agent: String, place: String)
    case confirmStartTask(agent: String, place: String, task: String)
    /// After a card, in an utterance with several requests: what comes next.
    case thenStatus(workspace: String)
    case thenNext
    case confirmReplyMany(text: String, workspaces: [String])
    case confirmApproveMany(workspaces: [String])
    /// Sessions left out of a card for several (unclear pane, nothing asked).
    case leftOut([String])
    case sayYesOrPressReturn
    case pressReturnToConfirm
    case voiceNotEnough
    case sent(workspace: String)
    case started(agent: String, place: String)
    case sentMany(count: Int)
    case failedIn([String])
    case noneWaiting
    case noneWorking
    case nothingToDo
    /// One session's line when going through them all.
    case session(workspace: String, summary: String)
    case failed
    case cancelled
    case expired
    case nothingToConfirm
    // The assistant itself.
    case wake
    case paused
    case goodbye
    case modelUnavailable
    /// A web question, but `claude` is not installed where the app looks.
    case claudeNotFound
    /// A web question, but `claude -p` failed or took too long.
    case webFailed
    /// An action the assistant could not work out (instead of the on-device model's apology).
    case cannotTell
    // Follow-through on a task it gave.
    case taskDone(agent: String, workspace: String)
    case taskAsks(agent: String, workspace: String, question: String)
    case taskNeedsYou(agent: String, workspace: String)

    public var english: String {
        switch self {
        case .noAgents: return "No agents are running."
        case .waitingList(let count, let names): return "\(count) waiting: \(names)."
        case .workingList(let count, let names): return "\(count) working: \(names)."
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
        case .whereToStart: return "Which folder should I start it in?"
        case .whichFolder(let folders): return "Which folder: \(folders.joined(separator: ", "))?"
        case .confirmReply(let text, let workspace): return "Send “\(text)” to \(workspace)?"
        case .confirmChoice(let number, let label, let workspace): return "Choose \(number), “\(label)”, in \(workspace)?"
        case .confirmStart(let agent, let place): return "Start \(agent) in \(place)?"
        case .confirmStartTask(let agent, let place, let task): return "Start \(agent) in \(place) with “\(task)”?"
        case .thenStatus(let workspace): return "Then I'll tell you how \(workspace) is doing."
        case .thenNext: return "Then I'll go on with the rest."
        case .confirmReplyMany(let text, let workspaces): return "Send “\(text)” to \(workspaces.joined(separator: ", "))?"
        case .confirmApproveMany(let workspaces): return "Choose option 1 in \(workspaces.joined(separator: ", "))?"
        case .leftOut(let workspaces): return "Left out: \(workspaces.joined(separator: ", "))."
        case .sayYesOrPressReturn: return "Say yes or press Return."
        case .pressReturnToConfirm: return "This one needs Return or a click."
        case .voiceNotEnough: return "Please press Return or click the button for this one."
        case .sent(let workspace): return "Sent to \(workspace)."
        case .started(let agent, let place): return "Started \(agent) in \(place)."
        case .sentMany(let count): return count == 1 ? "Sent to 1 session." : "Sent to \(count) sessions."
        case .failedIn(let workspaces): return "That didn't work in \(workspaces.joined(separator: ", ")): the pane is gone or busy."
        case .noneWaiting: return "No session is waiting for you."
        case .noneWorking: return "No agent is working."
        case .nothingToDo: return "There is nothing to send."
        case .session(let workspace, let summary): return "\(workspace): \(summary)"
        case .failed: return "That didn't work: the pane is gone or busy."
        case .cancelled: return "Cancelled."
        case .expired: return "I cancelled it: no answer."
        case .nothingToConfirm: return "There is nothing to confirm."
        case .wake: return "Yes?"
        case .paused: return "Listening paused."
        case .goodbye: return "Assistant off."
        case .modelUnavailable: return "I can only answer about the workspaces: the on-device model isn't available."
        case .claudeNotFound: return "I can't search the web: Claude Code (claude) isn't installed."
        case .webFailed: return "I couldn't get an answer from Claude: it failed or took too long."
        case .cannotTell: return "I couldn't tell what to do. Try “start Claude in api” or “tell api to run the tests”."
        case .taskDone(let agent, let workspace): return "\(agent) in \(workspace) is done."
        case .taskAsks(let agent, let workspace, let question): return "\(agent) in \(workspace) needs you: \(question)"
        case .taskNeedsYou(let agent, let workspace): return "\(agent) in \(workspace) needs you."
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

    /// Compact: "2 waiting: api, api-v2. 1 working: web." The agents' questions only when asked about one workspace.
    /// `list`: how names are joined (`api, web` / `api、web`).
    public static func status(_ world: AssistantWorld, strings: AssistantStrings,
                              list: ([String]) -> String = { $0.joined(separator: ", ") }) -> String {
        let agents = world.withAgents
        guard !agents.isEmpty else { return strings(.noAgents) }
        let waiting = agents.filter { $0.state == .needsUser }.map(\.title)
        let working = agents.filter { $0.state == .working }.map(\.title)
        guard !waiting.isEmpty || !working.isEmpty else { return strings(.allQuiet(count: agents.count)) }
        func names(_ titles: [String]) -> String {
            list(titles.prefix(maxNamed).map(clip)) + (titles.count > maxNamed ? " +\(titles.count - maxNamed)" : "")
        }
        var lines: [AssistantLine] = []
        if !waiting.isEmpty { lines.append(.waitingList(count: waiting.count, names: names(waiting))) }
        if !working.isEmpty { lines.append(.workingList(count: working.count, names: names(working))) }
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
        let flat = AssistantText.oneLine(text)
        return flat.count > 120 ? String(flat.prefix(119)) + "…" : flat
    }
}
