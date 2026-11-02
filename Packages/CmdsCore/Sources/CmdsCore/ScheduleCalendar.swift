import Foundation

/// When a schedule fires next. Pure, unit-tested (ScheduleCalendarTests).
public enum ScheduleCalendar {
    /// The next firing time of `trigger` after `date`, or nil when it does not fire again.
    /// - `once`: `at` while it is still ahead.
    /// - `weekly`: the earliest of its weekdays × times in the rule's zone (`timeZone` when it has none). A time in a
    ///   spring-forward gap fires at the first instant after the gap; a time repeated by a fall-back fires once.
    /// - `limitReset`: the account's `resetsAt + delay` while it has a limit (it may already have passed: the run is
    ///   then due at once, or late); `date` when the limit was cleared; nil when the account is gone.
    public static func nextFire(_ trigger: ScheduleTrigger, after date: Date, accounts: [ClaudeAccount],
                                timeZone: TimeZone = .current) -> Date? {
        switch trigger {
        case .once(let at):
            return at > date ? at : nil
        case .weekly(let rule):
            return nextWeekly(rule, after: date, timeZone: timeZone)
        case .limitReset(let name, let delay):
            guard let account = accounts.first(where: { $0.hasName(name) }) else { return nil }
            guard let limit = account.limit else { return date }
            return limit.resetsAt.addingTimeInterval(delay)
        }
    }

    /// The zone a weekly rule runs in: its own, else `fallback` (the Mac's).
    public static func zone(of rule: WeeklyRule, fallback: TimeZone = .current) -> TimeZone {
        rule.timeZone.flatMap(TimeZone.init(identifier:)) ?? fallback
    }

    public static func nextWeekly(_ rule: WeeklyRule, after date: Date, timeZone: TimeZone = .current) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone(of: rule, fallback: timeZone)
        var best: Date?
        for day in rule.weekdays {
            for time in rule.times {
                let wanted = DateComponents(hour: time.hour, minute: time.minute, second: 0, weekday: day.calendarWeekday)
                guard var next = calendar.nextDate(after: date, matching: wanted, matchingPolicy: .nextTime,
                                                   repeatedTimePolicy: .first, direction: .forward) else { continue }
                // A fall-back repeats an hour: its second pass is not another firing.
                if isRepeatedWallTime(next, calendar: calendar),
                   let later = calendar.nextDate(after: next, matching: wanted, matchingPolicy: .nextTime,
                                                 repeatedTimePolicy: .first, direction: .forward) {
                    next = later
                }
                if best.map({ next < $0 }) ?? true { best = next }
            }
        }
        return best
    }

    /// `date` shows a wall time that was already shown earlier the same day (the second pass of a fall-back hour).
    static func isRepeatedWallTime(_ date: Date, calendar: Calendar) -> Bool {
        let parts: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute]
        let wall = calendar.dateComponents(parts, from: date)
        // Fall-backs are 1 h almost everywhere (30 min on Lord Howe Island).
        return [1800.0, 3600.0].contains { calendar.dateComponents(parts, from: date.addingTimeInterval(-$0)) == wall }
    }
}

/// What to do with a schedule whose `nextFireAt` has come (or passed while the Mac slept or cmds was not running).
public enum ScheduleCatchUp {
    /// A firing this late still counts as on time (timer tolerance, the 60 s safety check).
    public static let onTimeGrace: TimeInterval = 90

    public enum Decision: Equatable, Sendable {
        case notDue
        case run(ScheduleRun.Cause)
        case missed
    }

    /// One run at most, however many slots passed: on time, or one `catchUp` within the late policy, else missed.
    public static func decide(nextFireAt: Date?, now: Date, late: ScheduleLatePolicy) -> Decision {
        guard let due = nextFireAt, due <= now else { return .notDue }
        let lateBy = now.timeIntervalSince(due)
        if lateBy <= onTimeGrace { return .run(.scheduled) }
        if case .runIfWithin(let window) = late, lateBy <= window { return .run(.catchUp) }
        return .missed
    }
}
