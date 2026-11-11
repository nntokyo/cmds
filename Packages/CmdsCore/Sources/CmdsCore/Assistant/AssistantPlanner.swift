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
    /// More actions confirmed together with this one (one card for several sessions): all run, or none.
    public var also: [AssistantAction]

    public init(kind: Kind, workspaceID: String?, workspaceTitle: String, paneID: String?, paneTitle: String?,
                text: String, label: String? = nil, reasons: [AssistantSafety.Reason], also: [AssistantAction] = []) {
        self.kind = kind
        self.workspaceID = workspaceID
        self.workspaceTitle = workspaceTitle
        self.paneID = paneID
        self.paneTitle = paneTitle
        self.text = text
        self.label = label
        self.reasons = reasons
        self.also = also
    }

    /// Several actions on one card: the first carries the others.
    public static func batch(_ actions: [AssistantAction]) -> AssistantAction? {
        guard var first = actions.first else { return nil }
        first.also = Array(actions.dropFirst())
        return first
    }

    /// This action and those confirmed with it, each on its own.
    public var all: [AssistantAction] {
        var first = self
        first.also = []
        return [first] + also.flatMap(\.all)
    }

    /// Why any of them needs Return or a click (each reason once).
    public var allReasons: [AssistantSafety.Reason] {
        AssistantSafety.Reason.allCases.filter { reason in all.contains { $0.reasons.contains(reason) } }
    }

    /// A spoken yes is enough only when it is enough for every one of them.
    public var confirmation: AssistantSafety.Confirmation { AssistantSafety.confirmation(for: allReasons) }
}

/// One session to report on when going through them all.
public struct AssistantSummaryItem: Equatable, Sendable {
    public var workspaceID: String
    /// The pane whose screen is summarised (nil: only the facts).
    public var paneID: String?
    /// "api", or "api › claude" when the workspace has several agents.
    public var title: String
    /// The facts, said when there is no summary.
    public var fallback: String

    public init(workspaceID: String, paneID: String?, title: String, fallback: String) {
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.title = title
        self.fallback = fallback
    }
}

/// What to do about an intent, worked out without the app (#243).
public enum AssistantPlan: Equatable, Sendable {
    /// Say and show this.
    case answer(String)
    /// Say a summary of a workspace's screen: by the on-device model (`detailed`: by `claude -p`), else `fallback`.
    case summarize(workspaceID: String, paneID: String?, detailed: Bool, fallback: String)
    /// Go through these sessions one after the other, a summary each (`detailed`: by `claude -p`).
    case summarizeEach([AssistantSummaryItem], detailed: Bool)
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
            if let names = several(name, in: world) {
                return plan(.replyMany(.named(names), text: text), world: world, strings: strings)
            }
            return pane(name, in: world, strings: strings) { workspace, pane in
                let action = AssistantAction(kind: .reply, workspaceID: workspace.id, workspaceTitle: workspace.title,
                                             paneID: pane.id, paneTitle: pane.title, text: text,
                                             reasons: AssistantSafety.reasons(text: text, sshPane: pane.isSSH))
                return propose(action, line: .confirmReply(text: text, workspace: workspace.title), strings: strings)
            }
        case .approve(let name):
            if let names = several(name, in: world) { return plan(.approveMany(.named(names)), world: world, strings: strings) }
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
        case .checkAll(let scope, let detailed):
            return checkAll(scope, detailed: detailed, world: world, strings: strings)
        case .replyMany(let scope, let text):
            return many(scope, world: world, strings: strings) { workspace, pane in
                .found(AssistantAction(kind: .reply, workspaceID: workspace.id, workspaceTitle: workspace.title,
                                       paneID: pane.id, paneTitle: pane.title, text: text,
                                       reasons: AssistantSafety.reasons(text: text, sshPane: pane.isSSH)))
            } line: { titles in .confirmReplyMany(text: text, workspaces: titles) }
        case .approveMany(let scope):
            return many(scope, world: world, strings: strings) { workspace, pane in
                guard let prompt = pane.prompt, let option = prompt.options.first(where: { $0.number == 1 }) else { return .skip }
                let context = pane.promptContext + [prompt.question ?? "", option.label]
                return .found(AssistantAction(kind: .choose(1), workspaceID: workspace.id, workspaceTitle: workspace.title,
                                              paneID: pane.id, paneTitle: pane.title, text: "1", label: option.label,
                                              reasons: AssistantSafety.reasons(text: "", context: context, sshPane: pane.isSSH)))
            } line: { titles in .confirmApproveMany(workspaces: titles) }
        }
    }

    /// "api と web", "api, web and docs": several workspaces, when the whole is no workspace's title and every part
    /// finds one.
    static func several(_ name: String?, in world: AssistantWorld) -> [String]? {
        guard let name, !world.workspaces.contains(where: { AssistantText.key($0.title).hasPrefix(AssistantText.key(name)) }) else {
            return nil
        }
        let parts = name.replacingOccurrences(of: #"\s*(?:,|、|，|&|と|\band\b)\s*"#, with: "\u{1F}", options: [.regularExpression, .caseInsensitive])
            .split(separator: "\u{1F}").map { AssistantIntent.target(String($0)) ?? "" }.filter { !$0.isEmpty }
        guard parts.count > 1 else { return nil }
        for part in parts {
            guard case .found = world.find(part) else { return nil }
        }
        return parts
    }

    /// The most sessions gone through at once (each takes a model call).
    public static let maxSessions = 8

    /// The workspaces `scope` means, or what to say instead (a name not found or ambiguous, nobody waiting).
    private static func workspaces(_ scope: AssistantScope, in world: AssistantWorld,
                                   strings: AssistantStrings) -> Result<[AssistantWorld.Workspace], PlanInstead> {
        switch scope {
        case .named(let names):
            var found: [AssistantWorld.Workspace] = []
            for name in names {
                switch world.find(name) {
                case .found(let workspace): if !found.contains(where: { $0.id == workspace.id }) { found.append(workspace) }
                case .ambiguous(let workspaces): return .failure(.init(.askBack(strings(.whichWorkspace(workspaces.map(\.title))))))
                case .notFound: return .failure(.init(.askBack(strings(.notFound(name)))))
                }
            }
            return .success(found)
        case .all:
            let agents = world.withAgents
            return agents.isEmpty ? .failure(.init(.answer(strings(.noAgents)))) : .success(agents)
        case .waiting:
            let waiting = world.withAgents.filter { $0.state == .needsUser }
            return waiting.isEmpty ? .failure(.init(.answer(strings(.noneWaiting)))) : .success(waiting)
        case .working:
            let working = world.withAgents.filter { $0.state == .working }
            return working.isEmpty ? .failure(.init(.answer(strings(.noneWorking)))) : .success(working)
        }
    }

    /// What to say instead of acting on several sessions.
    private struct PlanInstead: Error {
        let plan: AssistantPlan
        init(_ plan: AssistantPlan) { self.plan = plan }
    }

    private static func checkAll(_ scope: AssistantScope, detailed: Bool, world: AssistantWorld,
                                 strings: AssistantStrings) -> AssistantPlan {
        let found: [AssistantWorld.Workspace]
        switch workspaces(scope, in: world, strings: strings) {
        case .success(let list): found = list
        case .failure(let instead): return instead.plan
        }
        var items: [AssistantSummaryItem] = []
        for workspace in found {
            let fallback = AssistantReport.workspace(workspace, now: world.now, strings: strings)
            let agents = workspace.panes.filter { $0.agent != nil }
            if agents.count > 1 {
                for pane in agents {
                    items.append(AssistantSummaryItem(workspaceID: workspace.id, paneID: pane.id,
                                                      title: "\(workspace.title) › \(pane.title)", fallback: fallback))
                }
            } else {
                let pane: String?
                if case .found(let target) = AssistantWorld.targetPane(in: workspace) { pane = target.id } else { pane = nil }
                items.append(AssistantSummaryItem(workspaceID: workspace.id, paneID: pane, title: workspace.title, fallback: fallback))
            }
        }
        return .summarizeEach(Array(items.prefix(maxSessions)), detailed: detailed)
    }

    private enum PaneAction {
        case found(AssistantAction)
        /// Nothing to do there (no question to approve).
        case skip
    }

    /// One card for several sessions. A named workspace that is not found or not clear asks back; with all, waiting
    /// or working, sessions whose pane is unclear or that ask nothing are left out and said so.
    private static func many(_ scope: AssistantScope, world: AssistantWorld, strings: AssistantStrings,
                             action: (AssistantWorld.Workspace, AssistantWorld.Pane) -> PaneAction,
                             line: ([String]) -> AssistantLine) -> AssistantPlan {
        let found: [AssistantWorld.Workspace]
        switch workspaces(scope, in: world, strings: strings) {
        case .success(let list): found = list
        case .failure(let instead): return instead.plan
        }
        let named: Bool
        if case .named = scope { named = true } else { named = false }
        var actions: [AssistantAction] = []
        var leftOut: [String] = []
        for workspace in found {
            switch AssistantWorld.targetPane(in: workspace) {
            case .found(let pane):
                switch action(workspace, pane) {
                case .found(let proposed): actions.append(proposed)
                case .skip:
                    if named { return .answer(strings(.noQuestion(workspace: workspace.title))) }
                    leftOut.append(workspace.title)
                }
            case .ambiguous(let panes):
                if named { return .askBack(strings(.unclearPane(workspace: workspace.title, panes: panes.map(\.title)))) }
                leftOut.append(workspace.title)
            case .none:
                if named { return .answer(strings(.noAgentIn(workspace: workspace.title))) }
                leftOut.append(workspace.title)
            }
        }
        guard let batch = AssistantAction.batch(actions) else {
            return .answer(strings(scope == .waiting ? .noneWaiting : .nothingToDo))
        }
        var lines = [line(actions.map(\.workspaceTitle))]
        if !leftOut.isEmpty { lines.append(.leftOut(leftOut)) }
        lines.append(batch.confirmation == .voiceOrKey ? .sayYesOrPressReturn : .pressReturnToConfirm)
        return .propose(batch, prompt: strings.join(lines))
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
