import CmdsCore
import Foundation

/// The demo Mac's schedules (`-mock`, `SyncFeature.schedules`): one of each trigger and action, a run in progress and a
/// history with every result, relative to now. `-mockNoSchedules` sends an empty list (the empty state).
enum MockSchedules {
    static func message(now: Date = Date()) -> ServerMessage.Schedules {
        if ProcessInfo.processInfo.arguments.contains("-mockNoSchedules") { return .init(schedules: [], runs: []) }
        let hour: TimeInterval = 3600
        let day: TimeInterval = 86400
        func weekly(_ days: Set<Weekday>, _ time: String) -> ScheduleTrigger {
            .weekly(WeeklyRule(weekdays: days, times: [TimeOfDay(time)].compactMap { $0 }))
        }
        func next(_ trigger: ScheduleTrigger) -> Date? {
            guard case .weekly(let rule) = trigger else { return nil }
            return ScheduleCalendar.nextWeekly(rule, after: now)
        }
        func run(_ id: String, _ schedule: String, _ name: String, ago: TimeInterval, _ state: ScheduleRunState,
                 _ reason: ScheduleReason?, cause: ScheduleRun.Cause = .scheduled) -> ScheduleRun {
            let due = now.addingTimeInterval(-ago)
            return ScheduleRun(id: id, scheduleID: schedule, scheduleName: name, cause: cause, dueAt: due,
                               startedAt: due, endedAt: state.isActive ? nil : due.addingTimeInterval(40),
                               state: state, reason: reason)
        }

        let morning = weekly(Weekday.workdays, "09:00")
        let nightly = weekly(Set(Weekday.allCases), "02:00")
        let review = weekly([.mon, .thu], "18:00")
        let reviewing = run("r00000007", "s00000005", "Review PRs", ago: 120, .waitingForAgent, nil, cause: .manual)
        let history = [
            run("r00000006", "s00000003", "Nightly bench", ago: 7 * hour, .skipped, .otherProgram),
            run("r00000005", "s00000001", "Morning tests", ago: day + 2 * hour, .succeeded, .confirmed),
            run("r00000004", "s00000005", "Review PRs", ago: 2 * day + 3 * hour, .failed, .agentBusy),
            run("r00000003", "s00000004", "Codex follow-up", ago: 3 * day, .missed, .missed),
            run("r00000002", "s00000001", "Morning tests", ago: 4 * day, .succeeded, .confirmed, cause: .catchUp),
            run("r00000001", "s00000002", "Continue after limit", ago: 5 * day, .succeeded, .unconfirmed),
        ]
        func last(_ id: String) -> ScheduleRun? { history.first { $0.scheduleID == id } }

        let schedules = [
            SyncScheduleSummary(id: "s00000001", name: "Morning tests", enabled: true, trigger: morning,
                                action: .init(type: "startWorkspace"), nextFireAt: next(morning),
                                lastRun: last("s00000001")),
            SyncScheduleSummary(id: "s00000002", name: "Continue after limit", enabled: true,
                                trigger: .limitReset(account: "work", delay: 60),
                                action: .init(type: "continueSession", agent: .claude),
                                nextFireAt: now.addingTimeInterval(2 * hour + 660), lastRun: last("s00000002")),
            SyncScheduleSummary(id: "s00000003", name: "Nightly bench", enabled: true, trigger: nightly,
                                action: .init(type: "sendText", to: .shell), nextFireAt: next(nightly),
                                lastRun: last("s00000003")),
            SyncScheduleSummary(id: "s00000005", name: "Review PRs", enabled: true, trigger: review,
                                action: .init(type: "sendText", to: .agent), nextFireAt: next(review),
                                activeRun: reviewing, lastRun: last("s00000005")),
            SyncScheduleSummary(id: "s00000004", name: "Codex follow-up", enabled: false,
                                trigger: .codexLimitReset(delay: 120, repeats: true),
                                action: .init(type: "continueSession", agent: .codex), lastRun: last("s00000004")),
        ]
        return .init(schedules: schedules, runs: [reviewing] + history)
    }
}
