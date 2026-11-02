import Foundation

/// When a schedule fires next. Pure, unit-tested (ScheduleCalendarTests).
public enum ScheduleCalendar {
    /// The next firing time of `trigger` after `date`, or nil when it does not fire again.
    /// - `once`: `at` while it is still ahead.
    /// - `weekly`: the earliest of its weekdays × times in the rule's zone (`timeZone` when it has none). A time in a
    ///   spring-forward gap fires at the first instant after the gap; a time repeated by a fall-back fires once.
    /// - `limitReset` (once): the account's `resetsAt + delay` while it has a limit (it may already have passed: the
    ///   run is then due at once, or late); `date` when the limit was cleared; nil when the account is gone.
    /// - `codexLimitReset` (once): `codex.exhaustedReset + delay`; `date` when no window is used up (Codex is usable);
    ///   nil when Codex limits are not known (`recomputed` keeps the stored time then).
    /// - Repeating limit triggers: the reset + delay only when it is after `date` (the last firing handled, so one
    ///   reset never fires twice); nil otherwise, also when there is no limit (it waits for the next one).
    public static func nextFire(_ trigger: ScheduleTrigger, after date: Date, accounts: [ClaudeAccount],
                                codex: AgentLimits? = nil, timeZone: TimeZone = .current) -> Date? {
        switch trigger {
        case .once(let at):
            return at > date ? at : nil
        case .weekly(let rule):
            return nextWeekly(rule, after: date, timeZone: timeZone)
        case .limitReset(let name, let delay, let repeats):
            guard let account = accounts.first(where: { $0.hasName(name) }) else { return nil }
            return limitFire(reset: account.limit?.resetsAt, delay: delay, repeats: repeats, after: date)
        case .codexLimitReset(let delay, let repeats):
            guard let codex else { return nil }
            return limitFire(reset: codex.exhaustedReset, delay: delay, repeats: repeats, after: date)
        }
    }

    private static func limitFire(reset: Date?, delay: TimeInterval, repeats: Bool, after date: Date) -> Date? {
        guard let reset else { return repeats ? nil : date }
        let fire = reset.addingTimeInterval(delay)
        return !repeats || fire > date ? fire : nil
    }

    /// A limit trigger's `nextFireAt` after its account's or Codex's limits changed (other triggers keep theirs):
    /// - a one-shot follows the limit (`nextFire` after `now`);
    /// - a repeating one fires for a reset after the last firing handled (`lastDueAt`, else when it was created);
    /// - Codex limits that are not known (after a relaunch, before a Codex session reported them) keep the stored
    ///   time, and a repeating trigger never drops a pending firing it has not handled yet.
    public static func recomputed(_ schedule: Schedule, now: Date, accounts: [ClaudeAccount], codex: AgentLimits?,
                                  timeZone: TimeZone = .current) -> Date? {
        let trigger = schedule.trigger
        guard trigger.followsLimit else { return schedule.nextFireAt }
        if case .codexLimitReset = trigger, codex == nil { return schedule.nextFireAt }
        if case .limitReset(let name, _, _) = trigger, !accounts.contains(where: { $0.hasName(name) }) { return nil }
        guard trigger.repeats else { return nextFire(trigger, after: now, accounts: accounts, codex: codex, timeZone: timeZone) }
        let handled = schedule.lastDueAt ?? schedule.createdAt
        let next = nextFire(trigger, after: handled, accounts: accounts, codex: codex, timeZone: timeZone)
        if next == nil, let pending = schedule.nextFireAt, pending > handled { return pending }
        return next
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
