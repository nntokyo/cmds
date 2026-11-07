import CmdsCore
import Foundation

/// The schedules on the phone, read only (docs/internals/sync-protocol.md "Schedules", #45 phase 3): phones that list
/// `SyncFeature.schedules` get a `schedules` summary right after `welcome` and `state`, and again when the runner reports
/// a change, at most once per `SyncSchedules.interval`. What it carries is decided by `SyncSchedules` (CmdsCore): no
/// prompts, commands, texts, folders or session ids. There is no message to change or run a schedule.
extension SyncServer {
    func observeSchedules() {
        schedulesCancellable = AppController.shared.scheduleRunner.changes.sink { [weak self] _ in
            self?.schedulesDidChange()
        }
    }

    private var schedulePhones: [Client] {
        clients.values.filter { $0.authenticated && $0.wantsSchedules }
    }

    private func currentSchedules() -> ServerMessage {
        let runner = AppController.shared.scheduleRunner
        return .schedules(SyncSchedules.message(list: runner.list(), runs: runner.runs(scheduleID: nil,
                                                                                       limit: SyncSchedules.maxRuns)))
    }

    /// The summary for a phone that just connected (it may be ahead of the last broadcast).
    func sendSchedules(to client: Client) {
        send(currentSchedules(), to: client)
    }

    /// A change: one broadcast once `SyncSchedules.interval` has passed since the previous one.
    private func schedulesDidChange() {
        guard !schedulePhones.isEmpty else {
            lastSchedulesData = nil
            return
        }
        guard !schedulesScheduled else { return }
        schedulesScheduled = true
        let delay = SyncSchedules.delay(lastSentAt: lastSchedulesSentAt)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.broadcastSchedules() }
        }
    }

    private func broadcastSchedules() {
        schedulesScheduled = false
        let phones = schedulePhones
        guard !phones.isEmpty else { return }
        lastSchedulesSentAt = Date()
        guard let data = try? codec.encode(currentSchedules()), data != lastSchedulesData else { return }
        lastSchedulesData = data
        for client in phones { client.connection.send(data) }
    }
}
