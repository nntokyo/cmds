import Foundation

/// The "starts in 1 minute" notice with Skip (`Schedule.warn`). Pure, unit-tested.
public enum ScheduleNotice {
    /// How long before a firing the notice is shown.
    public static let lead: TimeInterval = 60

    /// When the notice for the schedule's next firing is shown; nil when it has none (off, no next firing, `warn` off).
    public static func time(of schedule: Schedule) -> Date? {
        guard schedule.enabled, schedule.warn, let next = schedule.nextFireAt else { return nil }
        return next.addingTimeInterval(-lead)
    }

    /// The notice is shown now: its time has come, the firing has not, and it was not shown for this firing time yet
    /// (`shownFor`). A late firing (catch-up) gets none.
    public static func isDue(_ schedule: Schedule, now: Date, shownFor: Date?) -> Bool {
        guard let at = time(of: schedule), let next = schedule.nextFireAt else { return false }
        return now >= at && now < next && shownFor != next
    }

    /// When the next notice is to be shown (the notice timer): the earliest notice time after `now` of a firing whose
    /// notice was not shown yet (`shownFor`, by schedule id).
    public static func nextTime(of schedules: [Schedule], after now: Date, shownFor: [String: Date]) -> Date? {
        schedules.filter { shownFor[$0.id] != $0.nextFireAt }.compactMap(time(of:)).filter { $0 > now }.min()
    }
}
