import AppIntents
import CmdsCore

/// Siri and Shortcuts (#282): the agents' status, and a request for the assistant. A morning or evening summary is a
/// Shortcuts personal automation running Agent Status; cmds keeps no schedule of its own for it. Nothing here acts:
/// a request that would send or start something waits on the assistant's card on the Mac, as when it is said.
@available(macOS 26.0, *)
struct AgentStatusIntent: AppIntent {
    static let title: LocalizedStringResource = LocalizedStringResource("Agent Status", comment: "Shortcuts action: the agents' status")
    static let description = IntentDescription(LocalizedStringResource("Which agents are working and which wait for you, as the assistant says it.",
                                                                        comment: "Shortcuts action description"))
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let assistant = AssistantController.shared, assistant.isUnlocked else { throw AssistantIntentError.unavailable }
        let text = AssistantReport.status(AgentOverview.assistantWorld(assistant.controller), strings: .localized)
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

@available(macOS 26.0, *)
struct AskAssistantIntent: AppIntent {
    static let title: LocalizedStringResource = LocalizedStringResource("Ask the Assistant", comment: "Shortcuts action: a request for the voice assistant")
    static let description = IntentDescription(LocalizedStringResource("Hands a request to the assistant as if you said it with its name. It answers on the Mac; anything it would do still waits for your yes there. Returns its answer.",
                                                                        comment: "Shortcuts action description"))
    static let openAppWhenRun = false

    @Parameter(title: LocalizedStringResource("Request", comment: "Shortcuts action parameter: what to ask the assistant"))
    var request: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask the assistant \(\.$request)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let assistant = AssistantController.shared, assistant.isUnlocked else { throw AssistantIntentError.unavailable }
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AssistantIntentError.empty }
        do {
            return .result(value: try await assistant.handleTyped(text) ?? "")
        } catch AssistantController.TypedRequestRefusal.off {
            throw AssistantIntentError.off
        } catch AssistantController.TypedRequestRefusal.paused {
            throw AssistantIntentError.paused
        }
    }
}

@available(macOS 26.0, *)
enum AssistantIntentError: Error, CustomLocalizedStringResourceConvertible {
    case unavailable, off, paused, empty

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unavailable: return LocalizedStringResource("The assistant is not available on this Mac.", comment: "Shortcuts error")
        case .off: return LocalizedStringResource("The assistant is off. Turn it on in the cmds menu bar.", comment: "Shortcuts error")
        case .paused: return LocalizedStringResource("The assistant is paused. Resume listening in the cmds menu bar.", comment: "Shortcuts error")
        case .empty: return LocalizedStringResource("Say what to ask the assistant.", comment: "Shortcuts error")
        }
    }
}

/// Siri phrases (en here, ja in AppShortcuts.xcstrings); each has to name the app.
@available(macOS 26.0, *)
struct CmdsAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AgentStatusIntent(),
                    phrases: ["\(.applicationName) status", "Agent status in \(.applicationName)", "What are my agents doing in \(.applicationName)"],
                    shortTitle: LocalizedStringResource("Agent Status", comment: "Shortcuts action: the agents' status"),
                    systemImageName: "waveform.circle")
        AppShortcut(intent: AskAssistantIntent(),
                    phrases: ["Ask \(.applicationName)", "Ask the \(.applicationName) assistant"],
                    shortTitle: LocalizedStringResource("Ask the Assistant", comment: "Shortcuts action: a request for the voice assistant"),
                    systemImageName: "bubble.left.and.text.bubble.right")
    }
}
