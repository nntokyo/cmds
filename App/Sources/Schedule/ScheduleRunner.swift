import AppKit
import Combine
import CmdsCore
import os
import UserNotifications

let scheduleLog = Logger(subsystem: "tokyo.n-n.cmds", category: "schedule")

/// What changed in the schedules (`ScheduleRunner.changes`; socket events `schedule.changed` / `schedule.run`).
enum ScheduleChange {
    /// A schedule was added, changed or removed (`id`), or all of them were reloaded (nil).
    case schedules(id: String?)
    /// A run started, moved on or ended.
    case run(ScheduleRun)
}

/// Runs the schedules (docs/guide/schedules.md; design in GitHub issue #45). Owned by `AppController`.
///
/// - Files: `schedules.json` and `schedule-runs.json` in the support directory (`ScheduleStore`); a damaged file is
///   moved aside and never overwritten; a file from a newer cmds makes everything read only.
/// - Firing: one timer for the earliest `nextFireAt`, re-armed on every change, after wake, clock, zone and day changes,
///   plus a 60 s safety check. A firing time that passed while the Mac slept or cmds was not running gets one
///   catch-up run within the late policy, else a missed entry (`ScheduleCatchUp`).
/// - Runs (ScheduleRunner+Runs.swift): a state machine per run, driven every 0.3 s by `ScheduleRunTiming`. Only the
///   run's own pane or the pane holding the targeted Claude Code session is typed into, once.
/// - Never logs prompts or commands.
@MainActor
final class ScheduleRunner {
    unowned let controller: AppController
    private let url: URL
    private let runsURL: URL

    private(set) var schedules: [Schedule] = []
    /// Ended runs, newest first (`ScheduleHistory.trimmed`).
    private(set) var history: [ScheduleRun] = []
    /// Runs in progress.
    var active: [ActiveScheduleRun] = []
    /// Nothing is saved: the files are from a newer cmds, or could not be read (`readOnlyReason`).
    private(set) var readOnly = false
    private(set) var readOnlyReason: String?
    /// A damaged file was moved aside to here at launch (shown once, and in the window).
    private(set) var movedAside: [URL] = []

    private let subject = PassthroughSubject<ScheduleChange, Never>()
    var changes: AnyPublisher<ScheduleChange, Never> { subject.eraseToAnyPublisher() }

    private var fireTimer: Timer?
    private var safetyTimer: Timer?
    var tickTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var started = false

    /// DEBUG builds: `debug.schedule_clock` moves the runner's clock (a simulated sleep, for catch-up tests).
    var clockOffset: TimeInterval = 0
    func now() -> Date { Date().addingTimeInterval(clockOffset) }

    /// The safety check while any schedule is enabled.
    private static let safetyInterval: TimeInterval = 60
    static let notificationCategory = "cmds.schedule"
    static let openSchedulesAction = "cmds.openSchedules"

    init(controller: AppController, supportDirectory: URL = CmdsEnv.supportDirectoryURL()) {
        self.controller = controller
        url = ScheduleStore.url(supportDirectory: supportDirectory)
        runsURL = ScheduleStore.runsURL(supportDirectory: supportDirectory)
    }

    // MARK: Lifecycle

    /// After session restore: load, catch up, arm the timers and watch for wake, clock and account changes.
    func start() {
        guard !started else { return }
        started = true
        load()
        let center = NotificationCenter.default
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated { self?.timeDidChange(zone: notification.name == .NSSystemTimeZoneDidChange) }
            })
        }
        observers.append(center.addObserver(forName: AppController.accountsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.accountsDidChange() }
        })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                // Timers stopped during sleep: what fell due is caught up (or missed) now.
                MainActor.assumeIsolated { self?.checkDue() }
            })
        checkDue()
    }

    /// cmds quits: active runs end (nothing more will be typed), the history is saved.
    func stop() {
        for run in active { finish(run, .cancelled, .appQuit, notify: false) }
        [fireTimer, safetyTimer, tickTimer].forEach { $0?.invalidate() }
        observers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    private func load() {
        switch StoredFile.load(ScheduleFile.self, from: url) {
        case .missing:
            break
        case .loaded(let file):
            schedules = file.schedules
            if file.dropped > 0 { scheduleLog.error("dropped \(file.dropped) invalid schedules from \(ScheduleStore.fileName, privacy: .public)") }
            if file.isFromNewerVersion { setReadOnly("version \(file.version)") }
        case .unreadable(let error, let movedTo):
            noteUnreadable(ScheduleStore.fileName, error: error, movedTo: movedTo)
        }
        switch StoredFile.load(ScheduleRunsFile.self, from: runsURL) {
        case .missing:
            break
        case .loaded(let file):
            history = ScheduleHistory.trimmed(file.runs, now: now())
            if file.isFromNewerVersion { setReadOnly("version \(file.version)") }
        case .unreadable(let error, let movedTo):
            noteUnreadable(ScheduleStore.runsFileName, error: error, movedTo: movedTo)
        }
        if !movedAside.isEmpty { showMovedAsideAlert() }
    }

    private func noteUnreadable(_ name: String, error: Error, movedTo: Result<URL, Error>) {
        switch movedTo {
        case .success(let moved):
            // Moved aside: start empty; the next save writes a new file.
            scheduleLog.error("\(name, privacy: .public) could not be decoded; moved to \(moved.lastPathComponent, privacy: .public)")
            movedAside.append(moved)
        case .failure:
            // Still in place (unreadable, or the move failed): never overwrite it.
            scheduleLog.error("\(name, privacy: .public) could not be read: \(String(describing: error), privacy: .public)")
            setReadOnly("unreadable \(name)")
        }
    }

    private func setReadOnly(_ reason: String) {
        readOnly = true
        readOnlyReason = reason
    }

    private func showMovedAsideAlert() {
        let names = movedAside.map(\.lastPathComponent).joined(separator: ", ")
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = String(localized: "Schedules could not be read")
            alert.informativeText = String(localized: "The damaged file was kept as \(names) in the cmds support folder, and cmds started with an empty one.")
            alert.addButton(withTitle: String(localized: "OK"))
            if let window = AppController.shared.window, window.isVisible {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    func save() {
        guard !readOnly else { return }
        do {
            try ScheduleStore.save(ScheduleFile(schedules: schedules), to: url)
        } catch {
            scheduleLog.error("could not save schedules: \(String(describing: error), privacy: .public)")
        }
    }

    func saveHistory() {
        guard !readOnly else { return }
        do {
            try ScheduleStore.save(ScheduleRunsFile(runs: history), to: runsURL)
        } catch {
            scheduleLog.error("could not save schedule runs: \(String(describing: error), privacy: .public)")
        }
    }

    func emit(_ change: ScheduleChange) { subject.send(change) }

    // MARK: Firing

    /// Fires every enabled schedule that is due: on time, one catch-up run, or a missed entry. Then each fired
    /// schedule's `nextFireAt` moves on from now (a one-shot is disabled and kept).
    func checkDue() {
        // Schedules of a newer cmds (or an unreadable file) are shown, never run.
        guard !readOnly else { return }
        let now = now()
        var changed = false
        for index in schedules.indices where schedules[index].enabled {
            let schedule = schedules[index]
            let decision = ScheduleCatchUp.decide(nextFireAt: schedule.nextFireAt, now: now, late: schedule.late)
            guard let due = schedule.nextFireAt, decision != .notDue else { continue }
            switch decision {
            case .notDue: continue
            case .run(let cause): startRun(schedule, cause: cause, dueAt: due)
            case .missed: recordMissed(schedule, dueAt: due)
            }
            advance(&schedules[index], after: max(now, due.addingTimeInterval(1)))
            changed = true
        }
        if changed {
            save()
            emit(.schedules(id: nil))
        }
        arm()
    }

    /// The next firing after `date`; a one-shot that fired is disabled.
    private func advance(_ schedule: inout Schedule, after date: Date) {
        if schedule.trigger.isOneShot {
            schedule.enabled = false
            schedule.nextFireAt = nil
        } else {
            schedule.nextFireAt = nextFire(schedule, after: date)
        }
    }

    func nextFire(_ schedule: Schedule, after date: Date) -> Date? {
        ScheduleCalendar.nextFire(schedule.trigger, after: date, accounts: controller.claudeAccounts.accounts, timeZone: .current)
    }

    /// One timer for the earliest firing; a 60 s check while anything is enabled.
    func arm() {
        fireTimer?.invalidate()
        fireTimer = nil
        let enabled = schedules.filter(\.enabled)
        if let earliest = enabled.compactMap(\.nextFireAt).min() {
            let timer = Timer(fire: max(Date(), earliest.addingTimeInterval(-clockOffset)), interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkDue() }
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            fireTimer = timer
        }
        if enabled.isEmpty {
            safetyTimer?.invalidate()
            safetyTimer = nil
        } else if safetyTimer == nil {
            let timer = Timer(timeInterval: Self.safetyInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkDue() }
            }
            RunLoop.main.add(timer, forMode: .common)
            safetyTimer = timer
        }
    }

    /// Clock, zone or day changed: catch up first, then recompute what is still ahead (a zone change moves weekly times
    /// that follow the Mac's zone).
    private func timeDidChange(zone: Bool) {
        if zone { NSTimeZone.resetSystemTimeZone() }
        checkDue()
        let now = now()
        for index in schedules.indices where schedules[index].enabled {
            if case .weekly = schedules[index].trigger { schedules[index].nextFireAt = nextFire(schedules[index], after: now) }
        }
        save()
        emit(.schedules(id: nil))
        arm()
    }

    /// Limits changed: a `limitReset` schedule follows its account's current limit.
    private func accountsDidChange() {
        let now = now()
        var changed = false
        for index in schedules.indices where schedules[index].enabled {
            guard case .limitReset = schedules[index].trigger else { continue }
            let next = nextFire(schedules[index], after: now)
            if next != schedules[index].nextFireAt {
                schedules[index].nextFireAt = next
                changed = true
            }
        }
        if changed {
            save()
            emit(.schedules(id: nil))
        }
        checkDue()
    }

    private func recordMissed(_ schedule: Schedule, dueAt: Date) {
        let now = now()
        let run = ScheduleRun(id: newRunID(), scheduleID: schedule.id, scheduleName: schedule.name, cause: .scheduled,
                              dueAt: dueAt, startedAt: now, endedAt: now, state: .missed, reason: .missed)
        scheduleLog.info("schedule \(schedule.id, privacy: .public) missed its run due \(dueAt.timeIntervalSince1970)")
        addToHistory(run)
        emit(.run(run))
        notify(run, schedule: schedule)
    }

    func newRunID() -> String {
        ScheduleIDs.make(prefix: ScheduleIDs.runPrefix, taken: Set(history.map(\.id) + active.map(\.record.id)))
    }

    func addToHistory(_ run: ScheduleRun) {
        history = ScheduleHistory.trimmed([run] + history, now: now())
        saveHistory()
    }

    // MARK: Queries

    func schedule(id: String) -> Schedule? { schedules.first { $0.id == id } }

    /// Why a schedule cannot run as it is (its account was removed); English, for the API.
    func problem(of schedule: Schedule) -> ScheduleProblem? {
        let accounts = controller.claudeAccounts.accounts
        func missing(_ name: String?) -> ScheduleProblem? {
            guard let name, name.lowercased() != ClaudeAccounts.automatic,
                  !accounts.contains(where: { $0.hasName(name) }) else { return nil }
            return .accountUnknown(name)
        }
        if case .limitReset(let account, _) = schedule.trigger, let problem = missing(account) { return problem }
        switch schedule.action {
        case .startWorkspace(let action):
            if action.account?.lowercased() == ClaudeAccounts.automatic, accounts.isEmpty { return .noAccounts }
            return missing(action.account)
        case .continueSession(let action):
            return missing(action.account)
        }
    }

    func entry(_ schedule: Schedule) -> ScheduleListEntry {
        ScheduleListEntry(schedule: schedule, nextFireAt: schedule.enabled ? schedule.nextFireAt : nil,
                          activeRun: active.first { $0.record.scheduleID == schedule.id }?.record,
                          lastRun: history.first { $0.scheduleID == schedule.id }, problem: problem(of: schedule)?.english)
    }

    func list() -> ScheduleList {
        ScheduleList(schedules: schedules.map(entry), readOnly: readOnly)
    }

    func runs(scheduleID: String?, limit: Int) -> [ScheduleRun] {
        let all = active.map(\.record) + history
        return Array(all.filter { scheduleID == nil || $0.scheduleID == scheduleID }.prefix(limit))
    }

    // MARK: Changes (API, window)

    private func requireWritable() throws {
        guard !readOnly else {
            throw RPCError.invalidParams("schedules are read only: "
                + (readOnlyReason?.hasPrefix("version") == true ? "the file was made by a newer cmds" : "the file could not be read"))
        }
    }

    /// What is wrong with a new or changed schedule. `full` false: editing other parts of a schedule whose time has
    /// passed (or whose limit is gone) is fine.
    func problems(_ draft: ScheduleDraft, excluding id: String?, full: Bool) -> [ScheduleProblem] {
        var problems = ScheduleValidation.problems(draft, accounts: controller.claudeAccounts.accounts,
                                                   existing: schedules.filter { $0.id != id }.count, now: now())
        if !full { problems.removeAll(where: Self.dependsOnNow) }
        return problems
    }

    private func validate(_ draft: ScheduleDraft, excluding id: String?, full: Bool) throws {
        let problems = problems(draft, excluding: id, full: full)
        guard problems.isEmpty else { throw RPCError.invalidParams(problems.map(\.english).joined(separator: "; ")) }
    }

    private static func dependsOnNow(_ problem: ScheduleProblem) -> Bool {
        switch problem {
        case .onceInPast, .accountNotLimited: return true
        default: return false
        }
    }

    @discardableResult
    func add(_ draft: ScheduleDraft, origin: ScheduleOrigin) throws -> Schedule {
        try requireWritable()
        try validate(draft, excluding: nil, full: true)
        let now = now()
        var schedule = Schedule(id: ScheduleIDs.make(prefix: ScheduleIDs.schedulePrefix, taken: Set(schedules.map(\.id))),
                                draft: draft, origin: origin, createdAt: now)
        schedule.nextFireAt = draft.enabled ? nextFire(schedule, after: now) : nil
        schedules.append(schedule)
        scheduleLog.info("added schedule \(schedule.id, privacy: .public) (\(schedule.trigger.type, privacy: .public), \(schedule.action.type, privacy: .public))")
        save()
        emit(.schedules(id: schedule.id))
        checkDue()
        return self.schedule(id: schedule.id) ?? schedule
    }

    /// Replaces the user's parts of a schedule. A new trigger, or turning it on, recomputes `nextFireAt` from now.
    @discardableResult
    func update(id: String, _ change: (inout ScheduleDraft) -> Void) throws -> Schedule {
        try requireWritable()
        guard let index = schedules.firstIndex(where: { $0.id == id }) else { throw RPCError.notFound("schedule not found: \(id)") }
        let old = schedules[index]
        var draft = old.draft
        change(&draft)
        let rearm = draft.trigger != old.trigger || (draft.enabled && !old.enabled)
        try validate(draft, excluding: id, full: rearm)
        schedules[index].draft = draft
        if !draft.enabled {
            schedules[index].nextFireAt = nil
        } else if rearm || schedules[index].nextFireAt == nil {
            schedules[index].nextFireAt = nextFire(schedules[index], after: now())
        }
        scheduleLog.info("changed schedule \(id, privacy: .public)")
        save()
        emit(.schedules(id: id))
        checkDue()
        return schedules[index]
    }

    /// Removes a schedule; its active run is cancelled, its history kept.
    func remove(id: String) throws {
        try requireWritable()
        guard let index = schedules.firstIndex(where: { $0.id == id }) else { throw RPCError.notFound("schedule not found: \(id)") }
        for run in active where run.record.scheduleID == id { finish(run, .cancelled, .scheduleRemoved, notify: false) }
        schedules.remove(at: index)
        scheduleLog.info("removed schedule \(id, privacy: .public)")
        save()
        emit(.schedules(id: id))
        arm()
    }

    /// Run Now: a manual run, also of a schedule that is off. Its `nextFireAt` stays.
    @discardableResult
    func runNow(id: String) throws -> ScheduleRun {
        try requireWritable()
        guard let schedule = schedule(id: id) else { throw RPCError.notFound("schedule not found: \(id)") }
        return startRun(schedule, cause: .manual, dueAt: now())
    }

    func cancel(runID: String) throws {
        guard let run = active.first(where: { $0.record.id == runID }) else {
            if history.contains(where: { $0.id == runID }) { throw RPCError.invalidParams("run \(runID) has already ended") }
            throw RPCError.notFound("run not found: \(runID)")
        }
        finish(run, .cancelled, .cancelledByUser, notify: false)
    }

    // MARK: Notifications

    /// Failed, skipped and missed runs: the run's pane gets attention, else a macOS notification with Open Schedules.
    /// Successful runs with `always`: the workspace's sidebar text, without a ring.
    func notify(_ run: ScheduleRun, schedule: Schedule?) {
        let policy = schedule?.notify ?? .failures
        guard policy != .never else { return }
        let title = String(localized: "Schedule “\(run.scheduleName)”")
        if run.state.isProblem {
            let body = ScheduleText.outcome(run)
            if let paneID = run.pane, let pane = controller.pane(id: paneID), !pane.isClosing {
                controller.raiseAttention(pane: pane, title: title, body: body)
            } else {
                postNotification(title: title, body: body)
            }
        } else if run.state == .succeeded, policy == .always {
            if let workspace = run.workspace, controller.workspace(id: workspace) != nil {
                try? controller.setStatus(workspaceID: workspace, text: "\(title): \(ScheduleText.outcome(run))")
            } else {
                postNotification(title: title, body: ScheduleText.outcome(run))
            }
        }
    }

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.notificationCategory
        content.userInfo = ["schedules": true]
        let request = UNNotificationRequest(identifier: "cmds.schedule.\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
