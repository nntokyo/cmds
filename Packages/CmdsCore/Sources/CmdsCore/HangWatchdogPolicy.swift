import Foundation

/// When cmds records a hang of its main thread (the app's `HangWatchdog`). A hang leaves no crash report, and
/// everything (windows, the socket API, `cmds ping`) waits on the main thread, so without a record there is nothing to
/// go on afterwards. A blocked main thread gets one `sample` of all threads per hang, written to `<support dir>/hangs`.
public enum HangWatchdogPolicy {
    /// How often the watchdog checks.
    public static let checkInterval: TimeInterval = 1
    /// From here on `system.ping` is answered off the main thread: busy, blocked for so long.
    public static let busyAfter: TimeInterval = 5
    /// Blocked this long: a sample is taken (once per hang).
    public static let recordAfter: TimeInterval = 30
    /// At most one sample this often, however many hangs.
    public static let minGapBetweenRecords: TimeInterval = 10 * 60
    /// Seconds `sample` watches the process.
    public static let sampleSeconds = 3
    /// Samples kept (the oldest go).
    public static let keep = 5
    public static let directoryName = "hangs"
    /// One line per hang: start, how long, the sample's file.
    public static let logName = "hangs.log"

    /// Take a sample now: blocked long enough, none taken in this hang yet, none taken recently.
    public static func shouldRecord(blockedFor: TimeInterval, recordedThisHang: Bool, lastRecordAt: Date?, now: Date) -> Bool {
        guard blockedFor >= recordAfter, !recordedThisHang else { return false }
        guard let lastRecordAt else { return true }
        return now.timeIntervalSince(lastRecordAt) >= minGapBetweenRecords
    }

    /// `hang-20261119-151644.txt`: sorts by time.
    public static func fileName(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "hang-\(formatter.string(from: date)).txt"
    }

    /// The samples to delete so that `keep` stay (oldest first by name); other files are left alone.
    public static func filesToDelete(_ names: [String], keep: Int = keep) -> [String] {
        let samples = names.filter { $0.hasPrefix("hang-") && $0.hasSuffix(".txt") }.sorted()
        return Array(samples.dropLast(keep))
    }

    /// A line of `hangs.log`: when it started, how long it lasted (nil: not over when cmds quit), the sample.
    public static func logLine(startedAt: Date, duration: TimeInterval?, file: String?) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        let length = duration.map { "\(Int($0.rounded())) s" } ?? "not over"
        return "\(formatter.string(from: startedAt))\t\(length)\t\(file ?? "-")\n"
    }
}
