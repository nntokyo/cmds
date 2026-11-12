import Foundation
import CmdsCore

/// The assistant's sentences from the app's String Catalog (docs/internals/localization.md): Japanese or English,
/// following the app's language, which is also the language it listens and speaks in.
extension AssistantStrings {
    static var localized: AssistantStrings {
        let language = AssistantLanguage.current
        return AssistantStrings(separator: language.sentenceSeparator, listSeparator: language.listSeparator) { line in
            line.localized
        }
    }
}

/// The language the assistant listens and speaks in: the app's (cmds › Language, else the system's).
struct AssistantLanguage: Equatable {
    /// `ja` or `en`.
    let code: String

    static var current: AssistantLanguage {
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        return AssistantLanguage(code: preferred.hasPrefix("ja") ? "ja" : "en")
    }

    var isJapanese: Bool { code == "ja" }
    /// Speech recognition and synthesis locale.
    var locale: Locale { Locale(identifier: isJapanese ? "ja_JP" : "en_US") }
    var voiceLanguage: String { isJapanese ? "ja-JP" : "en-US" }
    /// For the on-device model's instructions.
    var name: String { isJapanese ? "Japanese" : "English" }
    /// Between sentences: a space in English, nothing in Japanese.
    var sentenceSeparator: String { isJapanese ? "" : " " }
    /// Names in a sentence: `api, web` / `api、web`.
    var listSeparator: String { isJapanese ? "、" : ", " }
    func list(_ items: [String]) -> String { items.joined(separator: listSeparator) }
}

private extension AssistantLine {
    var localized: String {
        switch self {
        case .noAgents: return String(localized: "No agents are running.", comment: "assistant: spoken status")
        case .waitingList(let count, let names):
            return String(localized: "\(count) waiting: \(names).", comment: "assistant: spoken status (count and names of workspaces waiting for the user)")
        case .workingList(let count, let names):
            return String(localized: "\(count) working: \(names).", comment: "assistant: spoken status (count and names of workspaces whose agent works)")
        case .allQuiet(let count): return String(localized: "\(count) agents, nothing needs you.", comment: "assistant: spoken status")
        case .needsYou(let workspace): return String(localized: "\(workspace) needs you.", comment: "assistant: spoken status of a workspace")
        case .asks(let question): return String(localized: "It asks: \(question)", comment: "assistant: what the agent asks")
        case .working(let workspace): return String(localized: "\(workspace) is working.", comment: "assistant: spoken status of a workspace")
        case .workingOn(let workspace, let topic): return String(localized: "\(workspace) is working on \(topic).", comment: "assistant: spoken status of a workspace; topic = the agent's task")
        case .done(let workspace): return String(localized: "\(workspace) is done.", comment: "assistant: spoken status of a workspace")
        case .idle(let workspace): return String(localized: "\(workspace) is idle.", comment: "assistant: spoken status of a workspace")
        case .stopped(let workspace): return String(localized: "\(workspace) has stopped.", comment: "assistant: spoken status of a workspace")
        case .noAgentIn(let workspace): return String(localized: "No agent is running in \(workspace).", comment: "assistant")
        case .shellIdle: return String(localized: "Its shell is idle.", comment: "assistant: a workspace without an agent; its shell waits for a command")
        case .shellRunning(let command):
            return String(localized: "It is running \(command).", comment: "assistant: a workspace without an agent; command = the program its shell runs (vim, node)")
        case .agentIn(let agent, let workspace): return String(localized: "\(agent) in \(workspace).", comment: "assistant: which agent runs in a workspace")
        case .waitedMinutes(let minutes): return String(localized: "Waiting for \(minutes) minutes.", comment: "assistant: how long a workspace has waited")
        case .optionsOffered(let count, let first): return String(localized: "\(count) options, the first is \(first).", comment: "assistant: the agent's numbered choices")
        case .notFound(let name): return String(localized: "I can't find a workspace called \(name).", comment: "assistant")
        case .whichWorkspace(let titles):
            return String(localized: "Which one: \(AssistantLanguage.current.list(titles))?", comment: "assistant: asks back when several workspaces fit")
        case .nobodyWaiting: return String(localized: "No workspace is waiting for you. Which one do you mean?", comment: "assistant")
        case .unclearPane(let workspace, let panes):
            return String(localized: "\(workspace) has several panes (\(AssistantLanguage.current.list(panes))). Please use the reply panel.", comment: "assistant: it cannot tell which pane to send to")
        case .noQuestion(let workspace): return String(localized: "\(workspace) isn't asking anything.", comment: "assistant")
        case .noSuchOption(let workspace, let number): return String(localized: "\(workspace) has no option \(number).", comment: "assistant")
        case .unknownPlace(let name): return String(localized: "I don't know a workspace or folder called \(name).", comment: "assistant")
        case .whereToStart: return String(localized: "Which folder should I start it in?", comment: "assistant: asks where to start Claude Code or Codex")
        case .whichFolder(let folders):
            return String(localized: "Which folder: \(AssistantLanguage.current.list(folders))?", comment: "assistant: several project folders fit the name said")
        case .confirmReply(let text, let workspace): return String(localized: "Send “\(text)” to \(workspace)?", comment: "assistant: confirmation question")
        case .confirmChoice(let number, let label, let workspace):
            return String(localized: "Choose \(number), “\(label)”, in \(workspace)?", comment: "assistant: confirmation question")
        case .confirmStart(let agent, let place): return String(localized: "Start \(agent) in \(place)?", comment: "assistant: confirmation question")
        case .confirmStartTask(let agent, let place, let task):
            return String(localized: "Start \(agent) in \(place) with “\(task)”?", comment: "assistant: confirmation question; task = the first prompt the new agent gets")
        case .thenStatus(let workspace):
            return String(localized: "Then I'll tell you how \(workspace) is doing.", comment: "assistant: after a card, what it does next (several requests in one)")
        case .thenNext: return String(localized: "Then I'll go on with the rest.", comment: "assistant: after a card, the rest of what was asked follows")
        case .confirmReplyMany(let text, let workspaces):
            return String(localized: "Send “\(text)” to \(AssistantLanguage.current.list(workspaces))?", comment: "assistant: confirmation question for several sessions")
        case .confirmApproveMany(let workspaces):
            return String(localized: "Choose option 1 in \(AssistantLanguage.current.list(workspaces))?", comment: "assistant: confirmation question: say yes to several sessions")
        case .leftOut(let workspaces):
            return String(localized: "Left out: \(AssistantLanguage.current.list(workspaces)).", comment: "assistant: sessions not on the card (unclear pane or nothing asked)")
        case .sentMany(let count): return String(localized: "Sent to \(count) sessions.", comment: "assistant")
        case .failedIn(let workspaces):
            return String(localized: "That didn't work in \(AssistantLanguage.current.list(workspaces)): the pane is gone or busy.", comment: "assistant")
        case .noneWaiting: return String(localized: "No session is waiting for you.", comment: "assistant")
        case .noneWorking: return String(localized: "No agent is working.", comment: "assistant")
        case .nothingToDo: return String(localized: "There is nothing to send.", comment: "assistant")
        case .session(let workspace, let summary):
            return String(localized: "\(workspace): \(summary)", comment: "assistant: one session's line when going through them all")
        case .sayYesOrPressReturn: return String(localized: "Confirm by voice or press Return.", comment: "assistant: how to confirm")
        case .pressReturnToConfirm: return String(localized: "This one needs Return or a click.", comment: "assistant: how to confirm a dangerous action")
        case .voiceNotEnough: return String(localized: "Please press Return or click the button for this one.", comment: "assistant: a spoken yes is not enough")
        case .sent(let workspace): return String(localized: "Sent to \(workspace).", comment: "assistant")
        case .started(let agent, let place): return String(localized: "Started \(agent) in \(place).", comment: "assistant")
        case .failed: return String(localized: "That didn't work: the pane is gone or busy.", comment: "assistant")
        case .cancelled: return String(localized: "Cancelled.", comment: "assistant")
        case .skippedStart(let agent):
            return String(localized: "I won't start \(agent).", comment: "assistant: one card of several requests cancelled (the rest goes on): the start")
        case .skippedSend(let workspace):
            return String(localized: "I won't send it to \(workspace).", comment: "assistant: one card of several requests cancelled (the rest goes on): the reply")
        case .skippedChoice(let workspace):
            return String(localized: "I won't answer \(workspace).", comment: "assistant: one card of several requests cancelled (the rest goes on): the choice")
        case .skippedMany(let count):
            return String(localized: "I won't act on the \(count) sessions.", comment: "assistant: one card of several requests cancelled (the rest goes on): several sessions")
        case .expired: return String(localized: "I cancelled it: no answer.", comment: "assistant: a confirmation timed out")
        case .nothingToConfirm: return String(localized: "There is nothing to confirm.", comment: "assistant")
        case .wake: return String(localized: "Yes?", comment: "assistant: answer when called by name only")
        case .paused: return String(localized: "Listening paused.", comment: "assistant")
        case .goodbye: return String(localized: "Assistant off.", comment: "assistant")
        case .modelUnavailable:
            return String(localized: "I can only answer about the workspaces: the on-device model isn't available.", comment: "assistant: Apple Intelligence is off or unsupported")
        case .claudeNotFound:
            return String(localized: "I can't search the web: Claude Code (claude) isn't installed.", comment: "assistant: a web question, but claude is missing")
        case .cannotTell:
            return String(localized: "I couldn't tell what to do. Try “start Claude in api” or “tell api to run the tests”.", comment: "assistant: an action it could not work out")
        case .taskDone(let agent, let workspace):
            return String(localized: "\(agent) in \(workspace) is done.", comment: "assistant: a session it gave a task to finished its turn")
        case .taskAsks(let agent, let workspace, let question):
            return String(localized: "\(agent) in \(workspace) needs you: \(question)", comment: "assistant: a session it gave a task to asks something")
        case .taskNeedsYou(let agent, let workspace):
            return String(localized: "\(agent) in \(workspace) needs you.", comment: "assistant: a session it gave a task to waits for the user")
        case .webFailed:
            return String(localized: "I couldn't get an answer from Claude: it failed or took too long.", comment: "assistant: claude -p for a web question failed or timed out")
        case .checking:
            return String(localized: "Checking.", comment: "assistant: said at once while Claude works on a slow answer (web search, detailed summary)")
        }
    }
}
