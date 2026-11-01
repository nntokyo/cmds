import Foundation

/// A usage or rate limit Claude Code reported in a pane (`ClaudeLimitDetector`).
public struct ClaudeLimitHit: Equatable, Sendable {
    public var kind: ClaudeLimitKind
    /// From the message; nil when it had no (readable) time.
    public var resetsAt: Date?
    /// The line as shown (glyphs and box characters trimmed).
    public var line: String

    public init(kind: ClaudeLimitKind, resetsAt: Date?, line: String) {
        self.kind = kind
        self.resetsAt = resetsAt
        self.line = line
    }

    /// The limit to record for the account; without a reset time it is estimated (`fallbackDuration`).
    public func limit(now: Date = Date()) -> ClaudeAccountLimit {
        if let resetsAt, resetsAt > now {
            return ClaudeAccountLimit(kind: kind, resetsAt: resetsAt, estimated: false, detectedAt: now, message: line)
        }
        let reset = now.addingTimeInterval(ClaudeLimitDetector.fallbackDuration(kind))
        return ClaudeAccountLimit(kind: kind, resetsAt: reset, estimated: true, detectedAt: now, message: line)
    }
}

/// Recognises Claude Code's limit messages on a pane's screen and in its status-line limits.
///
/// Screen lines (the last `scannedLines` non-empty lines, newest first) must *start* with the message, after the
/// glyphs Claude Code puts in front (`⎿`, `⏺`, `●`, `│`, `>`), so a file or diff that merely contains the words does not
/// count:
/// - usage limit: `You've hit your limit · resets 3pm (Asia/Tokyo)`, `You've hit your weekly limit · resets Nov 7,
///   9am`, `5-hour limit reached ∙ resets 3pm`, `Claude usage limit reached. Your limit will reset at 3pm
///   (America/New_York).`, `Claude AI usage limit reached|1760000000`;
/// - rate limit: `API Error: 429 {"type":"error","error":{"type":"rate_limit_error",…}}`, `API Error: Rate limit
///   reached`, `Request rejected (429)`.
/// Warnings such as `Approaching usage limit · resets at 10pm` or `You've used 90% of your weekly limit` are not hits.
public enum ClaudeLimitDetector {
    public static let scannedLines = 40
    /// Claude Code's usage window: a usage limit without a reset time lasts this long.
    public static let sessionWindow: TimeInterval = 5 * 3600
    /// A rate limit without a reset time lasts this long.
    public static let rateLimitWait: TimeInterval = 15 * 60

    /// How long an account counts as limited when the message had no reset time.
    public static func fallbackDuration(_ kind: ClaudeLimitKind) -> TimeInterval {
        switch kind {
        case .usageLimit: return sessionWindow
        case .rateLimit: return rateLimitWait
        }
    }

    /// The newest limit message on `screen` (rows joined by "\n"), or nil.
    public static func detect(screen: String, now: Date = Date(), timeZone: TimeZone = .current) -> ClaudeLimitHit? {
        let lines = screen.components(separatedBy: "\n").map(clean).filter { !$0.isEmpty }
        let recent = lines.suffix(scannedLines)
        for index in recent.indices.reversed() {
            let line = recent[index]
            guard let kind = kind(of: line) else { continue }
            // A long message may wrap: the reset time can be on the next row.
            var reset = resetDate(in: line, now: now, timeZone: timeZone)
            if reset == nil, recent.indices.contains(index + 1) {
                reset = resetDate(in: line + " " + recent[index + 1], now: now, timeZone: timeZone)
            }
            return ClaudeLimitHit(kind: kind, resetsAt: reset, line: line)
        }
        return nil
    }

    /// A status-line window (5-hour, 7-day, spend) at 100 %: the account is limited until the latest such reset.
    public static func hit(fromLimits limits: [UsageLimit], now: Date = Date()) -> ClaudeLimitHit? {
        let full = limits.filter { $0.usedPercent >= 100 && ($0.resetsAt.map { $0 > now } ?? true) }
        guard !full.isEmpty else { return nil }
        let reset = full.compactMap(\.resetsAt).max()
        let names = full.map(\.id).joined(separator: ", ")
        return ClaudeLimitHit(kind: .usageLimit, resetsAt: reset, line: "status line: \(names) at 100%")
    }

    // MARK: Lines

    /// Without leading glyphs / box drawing and surrounding spaces; typographic apostrophes made plain.
    static func clean(_ line: String) -> String {
        let glyphs = CharacterSet(charactersIn: "⎿⏺●○•·✻✳✽│┃|>❯ \t\u{00A0}")
        var text = line.replacingOccurrences(of: "’", with: "'")
        while let first = text.unicodeScalars.first, glyphs.contains(first) { text.unicodeScalars.removeFirst() }
        text = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "│┃")))
        return text
    }

    private static let usagePattern = regex(
        #"^(?:error:\s*)?(?:you've (?:hit|reached) your\b.*\blimit\b|claude(?: ai)? usage limit reached|(?:[a-z0-9-]+ ){0,3}limit reached\b)"#)
    private static let ratePattern = regex(
        #"^(?:(?:api )?error\b.*(?:\b429\b|rate_limit_error|rate limit)|(?:api error: )?rate limit (?:reached|exceeded)|request rejected \(429\))"#)
    private static let warningWords = ["approaching", "you've used", "% of your", "will be reached"]

    static func kind(of line: String) -> ClaudeLimitKind? {
        let lower = line.lowercased()
        guard !warningWords.contains(where: lower.contains) else { return nil }
        let range = NSRange(lower.startIndex..., in: lower)
        // Rate limit first: "Rate limit reached" also has the shape of "<window> limit reached".
        if ratePattern.firstMatch(in: lower, range: range) != nil { return .rateLimit }
        if usagePattern.firstMatch(in: lower, range: range) != nil { return .usageLimit }
        return nil
    }

    // MARK: Reset times

    private static let epochPattern = regex(#"limit reached\|(\d{10,13})\b"#)
    private static let relativePattern = regex(
        #"\breset(?:s)?\s+in\s+(?:(\d{1,3})\s*(?:h|hr|hrs|hours?)\b)?\s*(?:(\d{1,4})\s*(?:m|min|mins|minutes?)\b)?"#)
    private static let absolutePattern = regex(
        #"\breset(?:s)?(?:\s+at)?[\s:]+(?:(mon|tue|wed|thu|fri|sat|sun)[a-z]*\.?,?\s+)?(?:(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(?:at\s+)?)?(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?(?:\s*\(([A-Za-z_]+(?:/[A-Za-z0-9_+\-]+){0,2})\))?"#)

    /// The reset time in a limit message: `…|<epoch>`, `resets in 2h 5m`, or a clock time with an optional weekday or
    /// month and day and an optional `(Area/City)` time zone (else `timeZone`). Clock times are the next one after `now`.
    static func resetDate(in text: String, now: Date, timeZone: TimeZone) -> Date? {
        let range = NSRange(text.startIndex..., in: text)
        if let match = epochPattern.firstMatch(in: text, range: range), let raw = group(match, 1, in: text),
           let number = Double(raw) {
            return FlexibleDate.date(epoch: number)
        }
        if let match = relativePattern.firstMatch(in: text, range: range) {
            let hours = group(match, 1, in: text).flatMap(Int.init)
            let minutes = group(match, 2, in: text).flatMap(Int.init)
            if hours != nil || minutes != nil {
                return now.addingTimeInterval(TimeInterval((hours ?? 0) * 3600 + (minutes ?? 0) * 60))
            }
        }
        guard let match = absolutePattern.firstMatch(in: text, range: range),
              var hour = group(match, 4, in: text).flatMap(Int.init) else { return nil }
        let minute = group(match, 5, in: text).flatMap(Int.init)
        let meridiem = group(match, 6, in: text)?.lowercased().replacingOccurrences(of: ".", with: "")
        // A bare number ("resets 3") is not a time.
        guard meridiem != nil || minute != nil, (0...59).contains(minute ?? 0) else { return nil }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (meridiem == "pm" ? 12 : 0)
        } else {
            guard (0...23).contains(hour) else { return nil }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = group(match, 7, in: text).flatMap(TimeZone.init(identifier:)) ?? timeZone
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        if let monthName = group(match, 2, in: text)?.lowercased().prefix(3), let month = months.firstIndex(of: String(monthName)),
           let day = group(match, 3, in: text).flatMap(Int.init), (1...31).contains(day) {
            let year = calendar.component(.year, from: now)
            for candidate in [year, year + 1] {
                let parts = DateComponents(year: candidate, month: month + 1, day: day, hour: hour, minute: minute ?? 0)
                // A date shown as "Nov 7" a little in the past is this year's (clock skew); a day or more back, next year's.
                if let date = calendar.date(from: parts), date > now.addingTimeInterval(-86400) { return date }
            }
            return nil
        }
        let time = DateComponents(hour: hour, minute: minute ?? 0, second: 0)
        if let weekdayName = group(match, 1, in: text)?.lowercased().prefix(3) {
            let weekdays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            guard let weekday = weekdays.firstIndex(of: String(weekdayName)) else { return nil }
            var parts = time
            parts.weekday = weekday + 1
            return calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime)
        }
        return calendar.nextDate(after: now, matching: time, matchingPolicy: .nextTime)
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}
