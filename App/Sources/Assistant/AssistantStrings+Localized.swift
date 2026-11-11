import Foundation
import CmdsCore

/// The assistant's sentences from the app's String Catalog (docs/internals/localization.md): Japanese or English,
/// following the app's language, which is also the language it listens and speaks in.
extension AssistantStrings {
    static var localized: AssistantStrings {
        AssistantStrings(separator: AssistantLanguage.current.isJapanese ? "" : " ") { line in line.localized }
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
    /// Names in a sentence: `api, web` / `api、web`.
    func list(_ items: [String]) -> String { items.joined(separator: isJapanese ? "、" : ", ") }
}

private extension AssistantLine {
    var localized: String {
        switch self {
        case .noAgents: return String(localized: "No agents are running.", comment: "assistant: spoken status")
        case .overview(let needYou, let working):
            switch (needYou, working) {
            case (0, _): return String(localized: "\(working) working.", comment: "assistant: spoken status (count of working agents)")
            case (_, 0): return String(localized: "\(needYou) need you.", comment: "assistant: spoken status (count of workspaces waiting for the user)")
            default: return String(localized: "\(needYou) need you, \(working) working.", comment: "assistant: spoken status")
            }
        case .allQuiet(let count): return String(localized: "\(count) agents, nothing needs you.", comment: "assistant: spoken status")
        case .needsYou(let workspace): return String(localized: "\(workspace) needs you.", comment: "assistant: spoken status of a workspace")
        case .asks(let question): return String(localized: "It asks: \(question)", comment: "assistant: what the agent asks")
        case .working(let workspace): return String(localized: "\(workspace) is working.", comment: "assistant: spoken status of a workspace")
        case .workingOn(let workspace, let topic): return String(localized: "\(workspace) is working on \(topic).", comment: "assistant: spoken status of a workspace; topic = the agent's task")
        case .done(let workspace): return String(localized: "\(workspace) is done.", comment: "assistant: spoken status of a workspace")
        case .idle(let workspace): return String(localized: "\(workspace) is idle.", comment: "assistant: spoken status of a workspace")
        case .stopped(let workspace): return String(localized: "\(workspace) has stopped.", comment: "assistant: spoken status of a workspace")
        case .noAgentIn(let workspace): return String(localized: "No agent is running in \(workspace).", comment: "assistant")
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
        case .confirmReply(let text, let workspace): return String(localized: "Send “\(text)” to \(workspace)?", comment: "assistant: confirmation question")
        case .confirmChoice(let number, let label, let workspace):
            return String(localized: "Choose \(number), “\(label)”, in \(workspace)?", comment: "assistant: confirmation question")
        case .confirmStart(let agent, let place): return String(localized: "Start \(agent) in \(place)?", comment: "assistant: confirmation question")
        case .sayYesOrPressReturn: return String(localized: "Say yes or press Return.", comment: "assistant: how to confirm")
        case .pressReturnToConfirm: return String(localized: "This one needs Return or a click.", comment: "assistant: how to confirm a dangerous action")
        case .voiceNotEnough: return String(localized: "Please press Return or click the button for this one.", comment: "assistant: a spoken yes is not enough")
        case .sent(let workspace): return String(localized: "Sent to \(workspace).", comment: "assistant")
        case .started(let agent, let place): return String(localized: "Started \(agent) in \(place).", comment: "assistant")
        case .failed: return String(localized: "That didn't work: the pane is gone or busy.", comment: "assistant")
        case .cancelled: return String(localized: "Cancelled.", comment: "assistant")
        case .expired: return String(localized: "I cancelled it: no answer.", comment: "assistant: a confirmation timed out")
        case .nothingToConfirm: return String(localized: "There is nothing to confirm.", comment: "assistant")
        case .wake: return String(localized: "Yes?", comment: "assistant: answer when called by name only")
        case .paused: return String(localized: "Listening paused.", comment: "assistant")
        case .goodbye: return String(localized: "Assistant off.", comment: "assistant")
        case .modelUnavailable:
            return String(localized: "I can only answer about the workspaces: the on-device model isn't available.", comment: "assistant: Apple Intelligence is off or unsupported")
        case .claudeNotFound:
            return String(localized: "I can't search the web: Claude Code (claude) isn't installed.", comment: "assistant: a web question, but claude is missing")
        case .webFailed:
            return String(localized: "I couldn't get an answer from Claude: it failed or took too long.", comment: "assistant: claude -p for a web question failed or timed out")
        }
    }
}
