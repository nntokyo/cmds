import Foundation

/// Something the assistant offers to do (#243). It is only shown (HUD card, spoken question) until the user confirms:
/// by voice only when `confirmation` is `.voiceOrKey`.
public struct AssistantAction: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Paste `text` into the pane, then Return (as the menu bar's reply panel does).
        case reply
        /// Type the option's number.
        case choose(Int)
        /// A new workspace in `directory` running the agent.
        case startAgent(AgentKind, directory: String)
    }

    public var kind: Kind
    /// The workspace and pane it goes to (start: none yet).
    public var workspaceID: String?
    public var workspaceTitle: String
    public var paneID: String?
    public var paneTitle: String?
    /// Exactly what is typed: the reply, the option's digit, the command.
    public var text: String
    /// The option's label, for `choose`.
    public var label: String?
    public var reasons: [AssistantSafety.Reason]

    public init(kind: Kind, workspaceID: String?, workspaceTitle: String, paneID: String?, paneTitle: String?,
                text: String, label: String? = nil, reasons: [AssistantSafety.Reason]) {
        self.kind = kind
        self.workspaceID = workspaceID
        self.workspaceTitle = workspaceTitle
        self.paneID = paneID
        self.paneTitle = paneTitle
        self.text = text
        self.label = label
        self.reasons = reasons
    }

    public var confirmation: AssistantSafety.Confirmation { AssistantSafety.confirmation(for: reasons) }
}

/// What to do about an intent, worked out without the app (#243).
public enum AssistantPlan: Equatable, Sendable {
    /// Say and show this.
    case answer(String)
    /// Say a summary of a workspace's screen: by the on-device model (`detailed`: by `claude -p`), else `fallback`.
    case summarize(workspaceID: String, paneID: String?, detailed: Bool, fallback: String)
    /// A free question for the on-device model.
    case ask(String)
    /// Show the action and ask to confirm (`prompt` is said).
    case propose(AssistantAction, prompt: String)
    /// Ask back (the follow-up window opens, so the answer needs no name).
    case askBack(String)
    case pauseListening
    case stop
    case confirm
    case cancel
}

public enum AssistantPlanner {
    /// `directoryExists` checks a folder said as a path (`~/src/app`).
    public static func plan(_ intent: AssistantIntent, world: AssistantWorld, strings: AssistantStrings,
                            directoryExists: (String) -> Bool = { _ in false }) -> AssistantPlan {
        switch intent {
        case .status:
            return .answer(AssistantReport.status(world, strings: strings))
        case .workspaceStatus(let name):
            return workspace(name, in: world, strings: strings) { workspace in
                summarize(workspace, detailed: false, world: world, strings: strings)
            }
        case .summary(let name, let detailed):
            guard name != nil || world.workspaces.filter({ $0.state == .needsUser }).count == 1 else {
                return .answer(AssistantReport.status(world, strings: strings))
            }
            return workspace(name, in: world, strings: strings) { workspace in
                summarize(workspace, detailed: detailed, world: world, strings: strings)
            }
        case .reply(let name, let text):
            return pane(name, in: world, strings: strings) { workspace, pane in
                let action = AssistantAction(kind: .reply, workspaceID: workspace.id, workspaceTitle: workspace.title,
                                             paneID: pane.id, paneTitle: pane.title, text: text,
                                             reasons: AssistantSafety.reasons(text: text, sshPane: pane.isSSH))
                return propose(action, line: .confirmReply(text: text, workspace: workspace.title), strings: strings)
            }
        case .approve(let name):
            return choose(1, name, world: world, strings: strings)
        case .choose(let name, let number):
            return choose(number, name, world: world, strings: strings)
        case .startAgent(let kind, let place):
            let directory: String
            switch world.find(place) {
            case .found(let workspace) where workspace.directory != nil:
                directory = workspace.directory!
            case .ambiguous(let workspaces):
                return .askBack(strings(.whichWorkspace(workspaces.map(\.title))))
            default:
                guard place.hasPrefix("/") || place.hasPrefix("~"), directoryExists(place) else {
                    return .askBack(strings(.unknownPlace(place)))
                }
                directory = place
            }
            let command = kind == .codex ? "codex" : "claude"
            let shown = (directory as NSString).abbreviatingWithTildeInPath
            let action = AssistantAction(kind: .startAgent(kind, directory: directory), workspaceID: nil,
                                         workspaceTitle: shown, paneID: nil, paneTitle: nil, text: command,
                                         reasons: AssistantSafety.reasons(text: command, sshPane: false))
            return propose(action, line: .confirmStart(agent: kind.displayName, place: shown), strings: strings)
        case .pauseListening: return .pauseListening
        case .stop: return .stop
        case .confirm: return .confirm
        case .cancel: return .cancel
        case .question(let text): return .ask(text)
        }
    }

    private static func summarize(_ workspace: AssistantWorld.Workspace, detailed: Bool, world: AssistantWorld,
                                  strings: AssistantStrings) -> AssistantPlan {
        let pane: String?
        if case .found(let found) = AssistantWorld.targetPane(in: workspace) { pane = found.id } else { pane = nil }
        return .summarize(workspaceID: workspace.id, paneID: pane, detailed: detailed,
                          fallback: AssistantReport.workspace(workspace, now: world.now, strings: strings))
    }

    private static func choose(_ number: Int, _ name: String?, world: AssistantWorld, strings: AssistantStrings) -> AssistantPlan {
        pane(name, in: world, strings: strings) { workspace, pane in
            guard let prompt = pane.prompt else { return .answer(strings(.noQuestion(workspace: workspace.title))) }
            guard let option = prompt.options.first(where: { $0.number == number }) else {
                return .answer(strings(.noSuchOption(workspace: workspace.title, number: number)))
            }
            let context = pane.promptContext + [prompt.question ?? "", option.label]
            let action = AssistantAction(kind: .choose(number), workspaceID: workspace.id, workspaceTitle: workspace.title,
                                         paneID: pane.id, paneTitle: pane.title, text: "\(number)", label: option.label,
                                         reasons: AssistantSafety.reasons(text: "", context: context, sshPane: pane.isSSH))
            return propose(action, line: .confirmChoice(number: number, label: option.label, workspace: workspace.title),
                           strings: strings)
        }
    }

    private static func propose(_ action: AssistantAction, line: AssistantLine, strings: AssistantStrings) -> AssistantPlan {
        let ask: AssistantLine = action.confirmation == .voiceOrKey ? .sayYesOrPressReturn : .pressReturnToConfirm
        return .propose(action, prompt: strings.join([line, ask]))
    }

    /// The workspace `name` means, or a question back.
    private static func workspace(_ name: String?, in world: AssistantWorld, strings: AssistantStrings,
                                  then: (AssistantWorld.Workspace) -> AssistantPlan) -> AssistantPlan {
        switch world.find(name) {
        case .found(let workspace): return then(workspace)
        case .ambiguous(let workspaces): return .askBack(strings(.whichWorkspace(workspaces.map(\.title))))
        case .notFound: return .askBack(name.map { strings(.notFound($0)) } ?? strings(.nobodyWaiting))
        }
    }

    /// The workspace and the one pane an action goes to, or a question back: never a guess.
    private static func pane(_ name: String?, in world: AssistantWorld, strings: AssistantStrings,
                             then: (AssistantWorld.Workspace, AssistantWorld.Pane) -> AssistantPlan) -> AssistantPlan {
        workspace(name, in: world, strings: strings) { workspace in
            switch AssistantWorld.targetPane(in: workspace) {
            case .found(let pane): return then(workspace, pane)
            case .ambiguous(let panes):
                return .askBack(strings(.unclearPane(workspace: workspace.title, panes: panes.map(\.title))))
            case .none: return .answer(strings(.noAgentIn(workspace: workspace.title)))
            }
        }
    }
}
