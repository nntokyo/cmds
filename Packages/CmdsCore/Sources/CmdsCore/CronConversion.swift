import Foundation

/// A Claude Code `CronCreate` expression (5 fields, the Mac's local time) as a cmds schedule trigger, so a session's
/// recurring job can move to a schedule that outlives restarts (#458). Only shapes a schedule can run exactly:
/// - every N minutes (`*/5 * * * *`, `3-58/5 * * * *`, `7/15 * * * *`; N divides an hour, at least 5) → `interval`
///   from midnight plus the first minute;
/// - every N hours at a minute (`0 * * * *`, `30 */2 * * *`; N divides a day) → `interval`;
/// - fixed minutes and hours on some weekdays (`0 9 * * 1-5`, `0,30 9,13 * * *`) → `weekly`.
/// Day-of-month and month must be `*`. Anything else is refused with the reason.
public enum CronConversion {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unsupported(String)

        public var description: String {
            switch self { case .unsupported(let why): return why }
        }
    }

    public static func trigger(_ cron: String, now: Date, timeZone: TimeZone = .current) -> Result<ScheduleTrigger, Failure> {
        let fields = cron.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else { return .failure(.unsupported("expected 5 fields")) }
        let (minute, hour, day, month, weekday) = (fields[0], fields[1], fields[2], fields[3], fields[4])
        guard day == "*", month == "*" else { return .failure(.unsupported("day of month and month must be *")) }
        let midnight = ScheduleCalendar.intervalStart(every: 86400, now: now, timeZone: timeZone)
        if minute == "*" { return .failure(.unsupported("more often than every 5 minutes")) }

        // Every N minutes.
        if hour == "*", weekday == "*", let (start, step) = stepped(minute, upTo: 59) {
            guard 60 % step == 0 else { return .failure(.unsupported("every \(step) minutes does not divide an hour")) }
            guard Double(step * 60) >= ScheduleLimits.intervalRange.lowerBound else {
                return .failure(.unsupported("more often than every 5 minutes"))
            }
            return .success(.interval(every: Double(step * 60), from: midnight.addingTimeInterval(Double(start * 60))))
        }
        // Every N hours at one minute.
        if weekday == "*", let minutes = values(minute, range: 0...59), minutes.count == 1 {
            let step: Int, startHour: Int
            if hour == "*" {
                (startHour, step) = (0, 1)
            } else if let (start, every) = stepped(hour, upTo: 23) {
                (startHour, step) = (start, every)
            } else {
                return weekly(minutes: minutes, hour: hour, weekday: weekday)
            }
            guard 24 % step == 0 else { return .failure(.unsupported("every \(step) hours does not divide a day")) }
            return .success(.interval(every: Double(step * 3600),
                                      from: midnight.addingTimeInterval(Double(startHour * 3600 + minutes[0] * 60))))
        }
        return weekly(minutes: values(minute, range: 0...59), hour: hour, weekday: weekday)
    }

    private static func weekly(minutes: [Int]?, hour: String, weekday: String) -> Result<ScheduleTrigger, Failure> {
        guard let minutes else { return .failure(.unsupported("minutes must be fixed (or */N with every hour)")) }
        guard let hours = values(hour, range: 0...23) else { return .failure(.unsupported("hours must be fixed")) }
        guard let days = weekdays(weekday) else { return .failure(.unsupported("unknown day of week \(weekday)")) }
        let times = hours.flatMap { h in minutes.compactMap { TimeOfDay(hour: h, minute: $0) } }.sorted()
        guard (1...ScheduleLimits.maxTimesPerDay).contains(times.count) else {
            return .failure(.unsupported("more than \(ScheduleLimits.maxTimesPerDay) times a day"))
        }
        let rule = WeeklyRule(weekdays: days, times: times)
        let draft = ScheduleDraft(name: "x", trigger: .weekly(rule),
                                  action: .sendText(SendText(target: .workspace(title: "x"), text: "x", to: .agent)))
        guard ScheduleValidation.problems(draft).isEmpty else {
            return .failure(.unsupported("times must be 5 minutes apart at least"))
        }
        return .success(.weekly(rule))
    }

    /// `*/N`, `M/N`, `M-59/N` (any end from the last firing on): (first, step). Nil for other shapes.
    static func stepped(_ field: String, upTo max: Int) -> (Int, Int)? {
        let parts = field.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let step = Int(parts[1]), step > 0 else { return nil }
        let base = parts[0]
        if base == "*" { return (0, step) }
        let bounds = base.split(separator: "-").map { Int($0) }
        guard let start = bounds.first ?? nil, (0...max).contains(start), start < step else { return nil }
        if bounds.count == 2 {
            // The range must reach the last firing of each hour or day, or the job would skip some.
            guard let end = bounds[1], end <= max, end >= start + ((max - start) / step) * step else { return nil }
        } else if bounds.count != 1 {
            return nil
        }
        return (start, step)
    }

    /// `5`, `0,30`, `9-17`, `*` (all): the values, sorted; nil for steps or anything out of range.
    static func values(_ field: String, range: ClosedRange<Int>) -> [Int]? {
        if field == "*" { return Array(range) }
        var result = Set<Int>()
        for part in field.split(separator: ",") {
            let bounds = part.split(separator: "-").map { Int($0) }
            guard let low = bounds.first ?? nil, range.contains(low) else { return nil }
            switch bounds.count {
            case 1: result.insert(low)
            case 2:
                guard let high = bounds[1], range.contains(high), high >= low else { return nil }
                result.formUnion(low...high)
            default: return nil
            }
        }
        return result.isEmpty ? nil : result.sorted()
    }

    /// Cron days of week: 0 or 7 Sunday … 6 Saturday, ranges and lists, or names (`mon-fri`).
    static func weekdays(_ field: String) -> Set<Weekday>? {
        let order: [Weekday] = [.sun, .mon, .tue, .wed, .thu, .fri, .sat]
        let names = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]
        let numeric = field.lowercased().split(separator: ",").map { part in
            part.split(separator: "-").map { names[String($0)].map(String.init) ?? String($0) }.joined(separator: "-")
        }.joined(separator: ",")
        guard let days = values(numeric.replacingOccurrences(of: "7", with: "0"), range: 0...6)
              ?? (numeric == "*" ? Array(0...6) : nil) else { return nil }
        return Set(days.map { order[$0] })
    }
}
