import AppKit
import CmdsCore

/// Tells one pane about panes that are stuck (`cmds stall`, API `stall.*`; docs/guide/queue.md "Stalled panes").
/// `StallNotice` decides; this class looks at the panes once a minute (the agents that ask for input, as `cmds idle`
/// counts them, and the first instruction waiting for each pane) and keeps one line per stall for the chosen pane
/// (`PaneQueueRunner`). It never types into the stalled pane, never answers a question and never brings a window
/// forward. Owned by `AppController`. Off until turned on (`stall-notice.json` in the support directory).
@MainActor
final class StallNoticeRunner {
    static let checkInterval: TimeInterval = 60

    unowned let controller: AppController
    private let url: URL
    private(set) var settings: StallNotice.Settings
    private var state = StallNotice.State()
    private var timer: Timer?
    private var last: (at: Date, lines: Int)?

    init(controller: AppController, supportDirectory: URL = CmdsEnv.supportDirectoryURL()) {
        self.controller = controller
        url = StallNotice.url(supportDirectory: supportDirectory)
        settings = StallNotice.loadSettings(from: url)
    }

    /// After session restore and `PaneQueueRunner.start`.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Lines that waited when cmds quit: what they say is told anew.
        withdrawLines()
    }

    /// The lines of this notice that wait in any pane's queue.
    private var waitingLines: [String] {
        controller.paneQueue.queue.items.filter { $0.from == StallNotice.queueSource }.map(\.id)
    }

    /// Takes back every line that still waits (not one that is being typed).
    private func withdrawLines() {
        for id in waitingLines { try? controller.paneQueue.cancel(id: id) }
    }

    /// The pane that is told, when it is open.
    private var target: Pane? {
        guard let tag = settings.toTag, case .pane(let id) = controller.resolveScheduleTarget(.tag(tag)) else { return nil }
        return controller.pane(id: id)
    }

    /// The stalls there are at `now`.
    private func stalls(now: Date) -> [StallNotice.Stall] {
        let asking = ((try? controller.idlePanes(minutes: IdlePanes.minutesRange.lowerBound))?.panes ?? [])
            .filter { $0.state == AgentActivity.needsInput.rawValue }
            .map { StallNotice.Asking(pane: $0.pane, seconds: $0.idleSeconds) }
        let waiting = controller.paneQueue.heads().map { head in
            StallNotice.Waiting(pane: head.pane?.id, tag: head.item.paneTag,
                                seconds: Int(now.timeIntervalSince(head.item.createdAt)), hold: head.hold, from: head.item.from)
        }
        return StallNotice.stalls(asking: asking, waiting: waiting, settings: settings, toPane: target?.id)
    }

    /// Keeps a line for the chosen pane for every stall that is due, and takes back the lines still waiting there
    /// for stalls that are over. A stall whose earlier line still waits gets no second one, and at most
    /// `StallNotice.maxWaitingLines` wait. A line that could not be kept (the pane's queue is full) is tried again at
    /// the next check.
    func check() {
        guard settings.enabled else { return }
        let now = Date()
        let stalls = stalls(now: now)
        for id in StallNotice.stale(stalls, state: &state, waiting: Set(waitingLines)) { try? controller.paneQueue.cancel(id: id) }
        guard let target else { return }
        var kept = 0
        let due = StallNotice.due(stalls, state: &state, now: now)
        for stall in StallNotice.toKeep(due, state: &state, now: now) {
            guard let line = try? controller.paneQueue.add(text: StallNotice.line(stall), paneID: target.id,
                                                           from: StallNotice.queueSource) else { continue }
            state.sent(stall, at: now, line: line.item.id)
            kept += 1
        }
        guard kept > 0 else { return }
        last = (now, kept)
        scheduleLog.info("stall notice: \(kept) lines kept")
    }

    // MARK: API

    func status() -> StallNoticeStatus {
        StallNoticeStatus(settings: settings, toPane: target?.id, stalls: stalls(now: Date()),
                          lastSentAt: last.map { ISO8601DateFormatter().string(from: $0.at) }, lastLines: last?.lines)
    }

    /// Changes what is given (`to`: the id of the pane that is told; it gets a tag, so it is found after a restart)
    /// and checks at once.
    func set(enabled: Bool?, to: String?, inputMinutes: Int?, queueMinutes: Int?) throws -> StallNoticeStatus {
        var changed = settings
        if let to {
            let pane = try controller.resolvePane(to)
            guard AppController.isScheduleTarget(pane) else { throw RPCError.invalidParams("the pane must be a local terminal pane") }
            changed.toTag = controller.scheduleTag(for: pane)
        }
        for (minutes, name) in [(inputMinutes, "input_minutes"), (queueMinutes, "queue_minutes")] {
            guard let minutes, !StallNotice.minutesRange.contains(minutes) else { continue }
            throw RPCError.invalidParams("\(name) must be \(StallNotice.minutesRange.lowerBound) to \(StallNotice.minutesRange.upperBound)")
        }
        if let inputMinutes { changed.inputMinutes = inputMinutes }
        if let queueMinutes { changed.queueMinutes = queueMinutes }
        if let enabled { changed.enabled = enabled }
        if changed.enabled, changed.toTag == nil { throw RPCError.invalidParams("choose the pane that is told first (to)") }
        if changed != settings {
            do {
                try StallNotice.save(changed, to: url)
            } catch {
                throw RPCError(code: 500, message: "the setting could not be saved: \(error.localizedDescription)")
            }
            let startsOver = StallNotice.startsOver(from: settings, to: changed)
            settings = changed
            if startsOver {
                state = StallNotice.State()
                withdrawLines()
            }
        }
        check()
        return status()
    }
}

/// `stall.status` and `stall.set` on the local socket (docs/reference/api.md). Never on an SSH pane's socket: the
/// methods are not in `RemoteAPIPolicy.allowedMethods`.
@MainActor
enum StallNoticeAPI {
    static func perform(_ method: String, _ params: Params, runner: StallNoticeRunner) throws -> JSONValue? {
        switch method {
        case "stall.status":
            return try .from(runner.status())
        case "stall.set":
            return try .from(runner.set(enabled: try params.bool("enabled"), to: try params.string("to"),
                                        inputMinutes: try params.int("input_minutes"), queueMinutes: try params.int("queue_minutes")))
        default:
            throw RPCError.methodNotFound(method)
        }
    }
}
