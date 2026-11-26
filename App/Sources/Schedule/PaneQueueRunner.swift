import AppKit
import CmdsCore

/// Keeps instructions for panes whose agent is working and types each in when the agent is free (`cmds queue`, API
/// `queue.*`; docs/guide/queue.md). Owned by `AppController`.
///
/// - File: `pane-queue.json` in the support directory (`PaneQueue`); a damaged file is moved aside, a file that
///   cannot be read is never written over.
/// - Typing: every `ScheduleRunTiming.tickInterval` while something waits, `PaneQueueTiming.step` decides from what
///   the pane shows (the checks of a schedule run, `Pane.typingObservation`). One instruction per pane at a time,
///   typed once: paste, Return, then it leaves the queue whatever follows.
/// - Never logs the text.
@MainActor
final class PaneQueueRunner {
    /// The head instruction of a pane on its way in.
    private struct Delivery {
        var itemID: String
        var phase = PaneQueueTiming.Phase.waiting
        var since: Date
        var enterAt: Date?
        var screen = ScreenStability()
    }

    unowned let controller: AppController
    private let url: URL
    private(set) var queue = PaneQueue()
    /// `pane-queue.json` is in place but could not be read: never written over (instructions are kept in memory only).
    private(set) var locked = false
    /// By pane tag.
    private var deliveries: [String: Delivery] = [:]
    private var holds: [String: PaneQueueHold] = [:]
    private var timer: Timer?
    /// Since when this cmds has watched its panes (`IdlePanes.Candidate.watchedSince`).
    let watchedSince = Date()

    init(controller: AppController, supportDirectory: URL = CmdsEnv.supportDirectoryURL()) {
        self.controller = controller
        url = PaneQueue.url(supportDirectory: supportDirectory)
    }

    /// After session restore (panes have their tags again): loads what waited when cmds quit.
    func start() {
        switch PaneQueue.load(from: url) {
        case .missing: break
        case .loaded(let loaded): queue = loaded
        case .unreadable(let error, let movedTo):
            if case .failure = movedTo { locked = true }
            scheduleLog.error("pane queue: the file could not be read: \(String(describing: error), privacy: .public)")
        }
        startTimerIfNeeded()
    }

    // MARK: API

    /// Keeps `text` for the pane (`paneID` nil: the focused one). The pane gets a tag, so it is found after a restart.
    /// `workspaceTitle` instead: the only terminal pane of the workspace with that title.
    func add(text: String, paneID: String?, workspaceTitle: String? = nil, from: String?) throws
        -> (item: PaneQueue.Item, pane: Pane, position: Int) {
        let pane: Pane
        if let workspaceTitle {
            guard paneID == nil else { throw RPCError.invalidParams("give pane or workspace, not both") }
            switch controller.resolveScheduleTarget(.workspace(title: workspaceTitle)) {
            case .pane(let id): pane = try controller.resolvePane(id)
            case .notFound: throw RPCError.notFound("no workspace titled \(workspaceTitle) with a terminal pane")
            case .ambiguous: throw RPCError.invalidParams("several terminal panes match the workspace title \(workspaceTitle); name one with pane")
            }
        } else {
            pane = try controller.resolvePane(paneID)
        }
        guard AppController.isScheduleTarget(pane) else {
            throw RPCError.invalidParams("instructions can be kept for local terminal panes only")
        }
        let item: PaneQueue.Item
        do {
            item = try queue.add(text: text, paneTag: controller.scheduleTag(for: pane), from: from, now: Date())
        } catch let problem as PaneQueue.Problem {
            throw RPCError.invalidParams(problem.message)
        }
        save()
        scheduleLog.info("pane queue: \(item.id, privacy: .public) kept for pane \(pane.id, privacy: .public)")
        startTimerIfNeeded()
        tick()
        return (item, pane, queue.position(of: item.id) ?? 1)
    }

    /// Takes a waiting instruction out. Not one that is being typed.
    func cancel(id: String) throws {
        guard let item = queue.items.first(where: { $0.id == id }) else { throw RPCError.notFound("instruction not found: \(id)") }
        if let delivery = deliveries[item.paneTag], delivery.itemID == id, delivery.phase != .waiting {
            throw RPCError.invalidParams("\(id) is being typed")
        }
        queue.end(id: id, .cancelled, now: Date())
        deliveries[item.paneTag] = nil
        holds[item.paneTag] = nil
        save()
    }

    func list() -> PaneQueueList {
        let formatter = ISO8601DateFormatter()
        let waiting = queue.items.map { item -> PaneQueueList.Entry in
            let pane = pane(tag: item.paneTag)
            let position = queue.position(of: item.id) ?? 1
            return PaneQueueList.Entry(id: item.id, pane: pane?.id,
                                       workspaceTitle: pane.flatMap { controller.workspace(id: $0.workspaceID)?.title },
                                       text: item.text, createdAt: formatter.string(from: item.createdAt), position: position,
                                       hold: position == 1 ? (pane == nil ? .paneNotFound : holds[item.paneTag]) : nil)
        }
        let recent = queue.recent.map {
            PaneQueueList.Ended(id: $0.id, pane: pane(tag: $0.paneTag)?.id, outcome: $0.outcome, endedAt: formatter.string(from: $0.endedAt))
        }
        return PaneQueueList(waiting: waiting, recent: recent)
    }

    /// An instruction is being pasted or sent in the pane: a schedule run waits (`otherInputInProgress`).
    func isTyping(in pane: Pane) -> Bool {
        guard let tag = pane.scheduleTag, let delivery = deliveries[tag] else { return false }
        return delivery.phase != .waiting
    }

    /// Instructions waiting for the pane.
    func waitingCount(for pane: Pane) -> Int {
        guard let tag = pane.scheduleTag else { return 0 }
        return queue.items.filter { $0.paneTag == tag }.count
    }

    /// An instruction from `source` (`PaneQueue.Item.from`) waits for the pane.
    func hasWaiting(from source: String, for pane: Pane) -> Bool {
        guard let tag = pane.scheduleTag else { return false }
        return queue.items.contains { $0.paneTag == tag && $0.from == source }
    }

    /// The first instruction waiting for each pane: its pane (nil: not open) and why it is not typed yet
    /// (`StallNotice`).
    func heads() -> [(item: PaneQueue.Item, pane: Pane?, hold: PaneQueueHold?)] {
        queue.paneTags.compactMap { tag in
            guard let item = queue.head(of: tag) else { return nil }
            let pane = pane(tag: tag).flatMap { $0.isClosing ? nil : $0 }
            return (item, pane, pane == nil ? .paneNotFound : holds[tag])
        }
    }

    // MARK: Typing

    private func pane(tag: String) -> Pane? {
        guard case .pane(let id) = controller.resolveScheduleTarget(.tag(tag)) else { return nil }
        return controller.pane(id: id)
    }

    private func startTimerIfNeeded() {
        guard timer == nil, !queue.items.isEmpty else { return }
        let timer = Timer(timeInterval: ScheduleRunTiming.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = Date()
        for tag in queue.paneTags {
            guard let item = queue.head(of: tag) else { continue }
            var delivery = deliveries[tag].flatMap { $0.itemID == item.id ? $0 : nil } ?? Delivery(itemID: item.id, since: now)
            step(item, tag: tag, delivery: &delivery, now: now)
            if queue.head(of: tag)?.id == item.id { deliveries[tag] = delivery } else { deliveries[tag] = nil }
        }
        if queue.items.isEmpty {
            timer?.invalidate()
            timer = nil
            deliveries.removeAll()
            holds.removeAll()
        }
    }

    private func step(_ item: PaneQueue.Item, tag: String, delivery: inout Delivery, now: Date) {
        let pane = pane(tag: tag).flatMap { $0.isClosing ? nil : $0 }
        let terminal = pane?.terminal
        var observation = ScheduleRunTiming.Observation()
        if let pane, let terminal {
            observation = pane.typingObservation(terminal, stability: &delivery.screen, checksAgentOnTerminal: delivery.phase == .waiting,
                                                 enterAt: delivery.enterAt, now: now)
            observation.otherInputInProgress = controller.scheduleRunner.active.contains { $0.record.pane == pane.id }
        } else {
            observation.paneExists = false
        }
        switch PaneQueueTiming.step(phase: delivery.phase, observation: observation, elapsed: now.timeIntervalSince(delivery.since)) {
        case .hold(let hold):
            holds[tag] = hold
        case .wait:
            break
        case .paste:
            guard let terminal else { return }
            holds[tag] = nil
            // A paste (bracketed when the agent asks for it), so line breaks stay in the text; Return follows.
            terminal.sendText(item.text)
            move(&delivery, to: .typing, now: now)
        case .enter:
            guard let terminal else { return end(item, .failed, now: now) }
            terminal.sendText("\r")
            delivery.enterAt = now
            move(&delivery, to: .confirming, now: now)
        case .end(let outcome):
            end(item, outcome, now: now)
        }
    }

    private func move(_ delivery: inout Delivery, to phase: PaneQueueTiming.Phase, now: Date) {
        delivery.phase = phase
        delivery.since = now
        delivery.screen.reset()
    }

    private func end(_ item: PaneQueue.Item, _ outcome: PaneQueue.Outcome, now: Date) {
        queue.end(id: item.id, outcome, now: now)
        holds[item.paneTag] = nil
        save()
        scheduleLog.info("pane queue: \(item.id, privacy: .public) \(outcome.rawValue, privacy: .public)")
    }

    private func save() {
        guard !locked else { return }
        do {
            try queue.save(to: url)
        } catch {
            scheduleLog.error("pane queue: cannot save: \(String(describing: error), privacy: .public)")
        }
    }
}

extension Pane {
    /// What a typing check sees in the pane (`ScheduleRunTiming.Observation`): a schedule run's and a queued
    /// instruction's. `checksAgentOnTerminal`: also list the terminal's processes for an agent behind a shell (before
    /// typing only; it lists every process). `enterAt`: when Return was pressed, to see the agent start.
    @MainActor
    func typingObservation(_ terminal: TerminalSurface, stability: inout ScreenStability, checksAgentOnTerminal: Bool,
                           enterAt: Date?, now: Date) -> ScheduleRunTiming.Observation {
        var o = ScheduleRunTiming.Observation()
        let (foreground, group) = inputForeground(terminal, now: now)
        let screen = terminal.visibleText()
        o.pane = inputObservation(terminal, screen: screen, foreground: foreground, stability: &stability, now: now)
        if foreground == .shell, let group, checksAgentOnTerminal {
            o.agentOnTerminal = PaneProcessProbe.agentOnTerminal(of: group)
        }
        if foreground == .agent {
            // Which agent: its process, else what it reports.
            o.agent = group.flatMap(PaneProcessProbe.agentKind(of:)) ?? agentUsage?.agent
            o.choiceOnScreen = ScheduleRunTiming.showsChoice(screen: screen)
            o.workingOnScreen = PaneReadiness.showsWorking(screen: screen)
            // Read with the styles only when the rest would let a prompt in (a placeholder is told by its style).
            if agentActivity != .busy, !o.workingOnScreen {
                let box: AgentInputBox.State
                if let rows = terminal.visibleStyledRows() {
                    box = AgentInputBox.state(rows: rows.map(\.text), runs: rows.map(\.runs))
                } else {
                    box = AgentInputBox.state(rows: screen.components(separatedBy: "\n"))
                }
                o.inputHasText = box == .typed
                // Codex draws no box cmds can be sure of: only Claude Code must show one.
                o.inputBoxMissing = box == .missing && o.agent == .claude
            }
        } else {
            o.agent = agentUsage?.agent
        }
        if let usage = agentUsage, usage.agent == o.agent {
            o.agentReported = true
            o.sessionID = usage.sessionID
        } else if foreground == .agent, let remembered = agentSession, remembered.agent == o.agent,
                  let group, let started = PaneProcessProbe.startDate(of: group), started <= remembered.lastSeen {
            o.rememberedSessionID = remembered.sessionID
        }
        o.accountSwitchInProgress = accountSwitch?.isInProgress == true
        o.resumeQueued = resumeRequestedAt != nil && resumeOffer != nil
        if let enterAt {
            o.promptSubmitted = agentActivity == .busy || agentSignals.workedSince(enterAt)
        }
        return o
    }
}

/// `queue.*` and `agent.idle` on the local socket (docs/reference/api.md). Never on an SSH pane's socket: the methods
/// are not in `RemoteAPIPolicy.allowedMethods`.
@MainActor
enum PaneQueueAPI {
    static func perform(_ method: String, _ params: Params, runner: PaneQueueRunner) throws -> JSONValue? {
        switch method {
        case "queue.add":
            let (item, pane, position) = try runner.add(text: try params.required("text"), paneID: try params.string("pane"),
                                                        workspaceTitle: try params.string("workspace"),
                                                        from: try params.string("from"))
            return ["id": .string(item.id), "pane": .string(pane.id), "position": .number(Double(position))]
        case "queue.list":
            return try .from(runner.list())
        case "queue.cancel":
            try runner.cancel(id: try params.required("id"))
            return nil
        default:
            throw RPCError.methodNotFound(method)
        }
    }
}

extension AppController {
    /// `agent.idle`: panes whose agent has had nothing in progress for `minutes` (`IdlePanes`).
    func idlePanes(minutes: Int?) throws -> IdlePaneReport {
        let minutes = minutes ?? IdlePanes.defaultMinutes
        guard IdlePanes.minutesRange.contains(minutes) else {
            throw RPCError.invalidParams("minutes must be \(IdlePanes.minutesRange.lowerBound) to \(IdlePanes.minutesRange.upperBound)")
        }
        let started = paneQueue.watchedSince
        let candidates = workspaces.flatMap { workspace in
            workspace.orderedPanes.filter { $0.kind == .terminal && !$0.isClosing }.map { pane -> IdlePanes.Candidate in
                // An agent never seen working: idle since it started, at the earliest since this cmds did.
                let agentStarted = pane.terminal?.foregroundProcessGroupID.flatMap(PaneProcessProbe.startDate(of:)) ?? .distantPast
                let typing = scheduleRunner.active.contains { $0.record.pane == pane.id } || paneQueue.isTyping(in: pane)
                return IdlePanes.Candidate(pane: pane.id, workspace: workspace.id, workspaceTitle: workspace.title,
                                           agent: pane.agentUsage?.agent, activity: pane.agentActivity,
                                           subagentRunning: pane.hasRunningSubagent, inputInProgress: typing,
                                           lastWorkAt: pane.agentSignals.lastBusyAt, watchedSince: max(started, agentStarted),
                                           queued: paneQueue.waitingCount(for: pane))
            }
        }
        return IdlePanes.report(candidates, minutes: minutes, now: Date())
    }
}
