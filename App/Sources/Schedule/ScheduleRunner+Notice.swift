import AppKit
import CmdsCore
import UserNotifications

/// "Schedule “X” starts in 1 minute" with Skip (`Schedule.warn`, `ScheduleNotice`): one notification per firing time,
/// `ScheduleNotice.lead` before a scheduled firing (none for catch-up or manual runs). Skip calls `skip(id:dueAt:)`,
/// which does nothing once that firing has moved on.
extension ScheduleRunner {
    static let noticeCategory = "cmds.schedule.notice"
    static let skipAction = "cmds.schedule.skip"
    nonisolated static let noticeScheduleKey = "scheduleID"
    nonisolated static let noticeDueKey = "dueAt"

    /// Shows the notices that are due and sets a timer for the next one.
    func armNotice() {
        noticeTimer?.invalidate()
        noticeTimer = nil
        guard !readOnly else { return }
        let now = now()
        for schedule in schedules where ScheduleNotice.isDue(schedule, now: now, shownFor: noticeShownFor[schedule.id]) {
            showNotice(schedule)
        }
        guard let next = ScheduleNotice.nextTime(of: schedules, after: now, shownFor: noticeShownFor) else { return }
        let timer = Timer(fire: next.addingTimeInterval(-clockOffset), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.armNotice() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        noticeTimer = timer
    }

    private func showNotice(_ schedule: Schedule) {
        guard let due = schedule.nextFireAt else { return }
        noticeShownFor[schedule.id] = due
        scheduleLog.info("schedule \(schedule.id, privacy: .public) notice for its run due \(due.timeIntervalSince1970)")
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Schedule “\(schedule.name)”")
        content.body = String(localized: "Starts at \(ScheduleStrings.time(due)): \(ScheduleText.action(schedule.action))")
        content.categoryIdentifier = Self.noticeCategory
        content.userInfo = ["schedules": true, Self.noticeScheduleKey: schedule.id, Self.noticeDueKey: due.timeIntervalSince1970]
        let request = UNNotificationRequest(identifier: Self.noticeIdentifier(schedule.id), content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// The firing came (or was skipped): its notice is no longer of use.
    func withdrawNotice(of id: String) {
        guard noticeShownFor[id] != nil else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.noticeIdentifier(id)])
    }

    private static func noticeIdentifier(_ id: String) -> String { "cmds.schedule.notice.\(id)" }

    /// The notice's Skip.
    func skipFromNotice(id: String, dueAt: Date) {
        do {
            try skip(id: id, dueAt: dueAt)
        } catch {
            scheduleLog.info("schedule \(id, privacy: .public) notice skip ignored: \(ScheduleText.error(error), privacy: .public)")
        }
    }
}
