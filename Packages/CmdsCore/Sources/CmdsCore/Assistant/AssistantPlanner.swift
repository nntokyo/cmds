import Foundation

/// Something the assistant offers to do (#243). It is only shown (HUD card, spoken question) until the user confirms:
/// by voice only when `confirmation` is `.voiceOrKey`.
public struct AssistantAction: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Paste `text` into the pane, then Return (as the menu bar's reply panel does).
        case reply
        /// Type the option's number.
        case choose(Int)
        /// A new workspace in `directory` running the agent (`text`: the command line), with `task` as its first prompt.
        case startAgent(AgentKind, directory: String, task: String?)
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
    /// `directoryExists` checks a folder said as a path (`~/src/app`); `folders` finds a project folder by name
    /// (`AssistantPlaces.find`); `executable` replaces `claude` / `codex` in a start's command (Debug tests only).
    public static func plan(_ intent: AssistantIntent, world: AssistantWorld, strings: AssistantStrings,
                            directoryExists: (String) -> Bool = { _ in false }, folders: (String) -> [String] = { _ in [] },
                            executable: String? = nil) -> AssistantPlan {
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
                propose(replyAction(text, workspace: workspace, pane: pane), line: .confirmReply(text: text, workspace: workspace.title),
                        strings: strings)
            }
        case .approve(let name):
            if let names = several(name, in: world) { return plan(.approveMany(.named(names)), world: world, strings: strings) }
            return choose(1, name, world: world, strings: strings)
        case .choose(let name, let number):
            return choose(number, name, world: world, strings: strings)
        case .startAgent(let kind, let place, let task):
            return start(kind, place: place, task: task, world: world, strings: strings, directoryExists: directoryExists,
                         folders: folders, executable: executable)
        case .delegate(let kind, let place, let task):
            // The agent already running there takes it; else a new one is started there with it.
            if case .found(let workspace) = world.find(place), case .found(let pane) = AssistantWorld.targetPane(in: workspace),
               let agent = pane.agent, AssistantText.key(agent).hasPrefix(AssistantText.key(kind.displayName)) {
                return plan(.reply(target: workspace.title, text: task), world: world, strings: strings)
            }
            return start(kind, place: place, task: task, world: world, strings: strings, directoryExists: directoryExists,
                         folders: folders, executable: executable)
        case .sequence(let intents):
            // The first now; the app goes on with the rest after it (and after its card). A card says what comes next.
            guard let first = intents.first else { return .ask("") }
            let planned = plan(first, world: world, strings: strings, directoryExists: directoryExists, folders: folders,
                               executable: executable)
            guard case .propose(let action, let prompt) = planned, intents.count > 1 else { return planned }
            return .propose(action, prompt: strings.joined([prompt, strings(next(intents[1], world: world))]))
        case .pauseListening: return .pauseListening
        case .stop: return .stop
        case .confirm: return .confirm
        case .cancel: return .cancel
        case .question(let text): return .ask(text)
        case .checkAll(let scope, let detailed):
            return checkAll(scope, detailed: detailed, world: world, strings: strings)
        case .replyMany(let scope, let text):
            return many(scope, world: world, strings: strings) { workspace, pane in
                .found(replyAction(text, workspace: workspace, pane: pane))
            } line: { titles in .confirmReplyMany(text: text, workspaces: titles) }
        case .approveMany(let scope):
            return many(scope, world: world, strings: strings) { workspace, pane in
                guard let prompt = pane.prompt, let option = prompt.options.first(where: { $0.number == 1 }) else { return .skip }
                return .found(chooseAction(option, of: prompt, workspace: workspace, pane: pane))
            } line: { titles in .confirmApproveMany(workspaces: titles) }
        }
    }

    /// Starting an agent: in the folder of the workspace named (also as misheard), a folder path, or a project folder
    /// of that name; without a place, where the last request was about, else the selected workspace. Never a guess:
    /// otherwise it asks which folder.
    private static func start(_ kind: AgentKind, place: String?, task: String?, world: AssistantWorld, strings: AssistantStrings,
                              directoryExists: (String) -> Bool, folders: (String) -> [String], executable: String?) -> AssistantPlan {
        let directory: String
        if let place {
            switch world.find(place) {
            case .found(let workspace) where workspace.directory != nil:
                directory = workspace.directory!
            case .ambiguous(let workspaces):
                return .askBack(strings(.whichWorkspace(workspaces.map(\.title))))
            default:
                if place.hasPrefix("/") || place.hasPrefix("~") {
                    guard directoryExists(place) else { return .askBack(strings.join([.unknownPlace(place), .whereToStart])) }
                    directory = place
                } else {
                    let found = folders(place)
                    switch found.count {
                    case 0: return .askBack(strings.join([.unknownPlace(place), .whereToStart]))
                    case 1: directory = found[0]
                    default: return .askBack(strings(.whichFolder(found.prefix(3).map(abbreviated))))
                    }
                }
            }
        } else if let id = world.recentID ?? world.focusedID, let workspace = world.workspace(id: id),
                  let folder = workspace.directory {
            directory = folder
        } else {
            return .askBack(strings(.whereToStart))
        }
        let task = task.flatMap(AssistantLaunch.cleaned)
        let command = AssistantLaunch.command(kind, task: task, executable: executable)
        let shown = abbreviated(directory)
        let action = AssistantAction(kind: .startAgent(kind, directory: directory, task: task), workspaceID: nil,
                                     workspaceTitle: shown, paneID: nil, paneTitle: nil, text: command,
                                     reasons: AssistantSafety.reasons(text: task ?? command, sshPane: false))
        let line: AssistantLine = task.map { .confirmStartTask(agent: kind.displayName, place: shown, task: $0) }
            ?? .confirmStart(agent: kind.displayName, place: shown)
        return propose(action, line: line, strings: strings)
    }

    /// `~/Source/app` for a folder in the home folder.
    static func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    /// What a card says comes after it, in an utterance with several requests.
    public static func next(_ intent: AssistantIntent, world: AssistantWorld) -> AssistantLine {
        switch intent {
        case .workspaceStatus(let name), .summary(let name?, _):
            if case .found(let workspace) = world.find(name) { return .thenStatus(workspace: workspace.title) }
            return .thenNext
        default:
            return .thenNext
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
                items.append(AssistantSummaryItem(workspaceID: workspace.id, paneID: AssistantWorld.targetPane(in: workspace).found?.id,
                                                  title: workspace.title, fallback: fallback))
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
            if leftOut.count == 1, let only = found.first(where: { $0.title == leftOut[0] }),
               case .found = AssistantWorld.targetPane(in: only) {
                return .answer(strings(.noQuestion(workspace: only.title)))
            }
            return .answer(strings.join([.nothingToDo] + (leftOut.isEmpty ? [] : [.leftOut(leftOut)])))
        }
        var lines = [line(actions.map(\.workspaceTitle))]
        if !leftOut.isEmpty { lines.append(.leftOut(leftOut)) }
        lines.append(howToConfirm(batch))
        return .propose(batch, prompt: strings.join(lines))
    }

    private static func summarize(_ workspace: AssistantWorld.Workspace, detailed: Bool, world: AssistantWorld,
                                  strings: AssistantStrings) -> AssistantPlan {
        .summarize(workspaceID: workspace.id, paneID: AssistantWorld.targetPane(in: workspace).found?.id, detailed: detailed,
                   fallback: AssistantReport.workspace(workspace, now: world.now, strings: strings))
    }

    private static func choose(_ number: Int, _ name: String?, world: AssistantWorld, strings: AssistantStrings) -> AssistantPlan {
        pane(name, in: world, strings: strings) { workspace, pane in
            guard let prompt = pane.prompt else { return .answer(strings(.noQuestion(workspace: workspace.title))) }
            guard let option = prompt.options.first(where: { $0.number == number }) else {
                return .answer(strings(.noSuchOption(workspace: workspace.title, number: number)))
            }
            return propose(chooseAction(option, of: prompt, workspace: workspace, pane: pane),
                           line: .confirmChoice(number: number, label: option.label, workspace: workspace.title), strings: strings)
        }
    }

    private static func propose(_ action: AssistantAction, line: AssistantLine, strings: AssistantStrings) -> AssistantPlan {
        .propose(action, prompt: strings.join([line, howToConfirm(action)]))
    }

    /// The card's last sentence: how to confirm it.
    private static func howToConfirm(_ action: AssistantAction) -> AssistantLine {
        action.confirmation == .voiceOrKey ? .sayYesOrPressReturn : .pressReturnToConfirm
    }

    // MARK: Cards

    /// Typing `text` (then Return) into the pane.
    private static func replyAction(_ text: String, workspace: AssistantWorld.Workspace, pane: AssistantWorld.Pane) -> AssistantAction {
        AssistantAction(kind: .reply, workspaceID: workspace.id, workspaceTitle: workspace.title, paneID: pane.id,
                        paneTitle: pane.title, text: text, reasons: AssistantSafety.reasons(text: text, sshPane: pane.isSSH))
    }

    /// Typing the option's number, checked with what the agent asks and the screen above it.
    private static func chooseAction(_ option: AgentPromptOptions.Option, of prompt: AgentPromptOptions,
                                     workspace: AssistantWorld.Workspace, pane: AssistantWorld.Pane) -> AssistantAction {
        let context = pane.promptContext + [prompt.question ?? "", option.label]
        return AssistantAction(kind: .choose(option.number), workspaceID: workspace.id, workspaceTitle: workspace.title,
                               paneID: pane.id, paneTitle: pane.title, text: "\(option.number)", label: option.label,
                               reasons: AssistantSafety.reasons(text: "", context: context, sshPane: pane.isSSH))
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
