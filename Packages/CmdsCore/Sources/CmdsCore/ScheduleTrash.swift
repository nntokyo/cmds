import Foundation

/// A schedule that left `schedules.json`: removed by someone, or dropped while the file was read (invalid or
/// undecodable). Kept as the JSON it was, so even one that no longer decodes can be read back by hand (#449).
public struct DeletedSchedule: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// `schedule.remove` or the window's Remove.
        case removed
        /// Dropped while `schedules.json` was read; `problem` says why.
        case dropped
    }

    /// The schedule as it was stored (`Schedule` JSON, or whatever the element was).
    public var schedule: JSONValue
    public var deletedAt: Date
    public var reason: Reason
    /// `dropped`: why it could not be kept.
    public var problem: String?
    /// `removed`: the window, or the API with the calling pane.
    public var removedBy: ScheduleOrigin?

    public init(schedule: JSONValue, deletedAt: Date, reason: Reason, problem: String? = nil,
                removedBy: ScheduleOrigin? = nil) {
        self.schedule = schedule
        self.deletedAt = deletedAt
        self.reason = reason
        self.problem = problem
        self.removedBy = removedBy
    }

    /// The schedule's id and name as stored (nil when the element has none).
    public var id: String? { schedule["id"]?.stringValue }
    public var name: String? { schedule["name"]?.stringValue }

    /// The schedule, when it still decodes.
    public var decoded: Schedule? { try? schedule.decode(Schedule.self) }

    private enum CodingKeys: String, CodingKey { case schedule, deletedAt, reason, problem, removedBy }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schedule = try c.decode(JSONValue.self, forKey: .schedule)
        guard let deletedAt = c.lenientDate(.deletedAt) else {
            throw DecodingError.dataCorruptedError(forKey: .deletedAt, in: c, debugDescription: "missing deletedAt")
        }
        self.deletedAt = deletedAt
        reason = (try? c.decodeIfPresent(Reason.self, forKey: .reason)) ?? .removed
        problem = c.lenientString(.problem)
        removedBy = try? c.decodeIfPresent(ScheduleOrigin.self, forKey: .removedBy)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schedule, forKey: .schedule)
        try c.encode(deletedAt.timeIntervalSince1970, forKey: .deletedAt)
        try c.encode(reason, forKey: .reason)
        try c.encodeIfPresent(problem, forKey: .problem)
        try c.encodeIfPresent(removedBy, forKey: .removedBy)
    }
}

/// `schedules-deleted.json`: `{"version": 1, "deleted": [...]}`, newest first. Mac only (not synced); readable by the
/// user only, like `schedules.json` (prompts are plain text).
public struct ScheduleTrash: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let fileName = "schedules-deleted.json"
    /// How long a deleted schedule is kept.
    public static let retention: TimeInterval = 30 * 86400
    public static let maxEntries = 100

    public var version: Int
    public var deleted: [DeletedSchedule]

    public init(deleted: [DeletedSchedule] = [], version: Int = ScheduleTrash.currentVersion) {
        self.version = version
        self.deleted = deleted
    }

    public static func url(supportDirectory: URL = CmdsEnv.supportDirectoryURL()) -> URL {
        supportDirectory.appendingPathComponent(fileName)
    }

    private enum CodingKeys: String, CodingKey { case version, deleted }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.lenientInt(.version) ?? 1
        let raw = (try? c.decodeIfPresent([JSONValue].self, forKey: .deleted)) ?? []
        deleted = raw.compactMap { try? $0.decode(DeletedSchedule.self) }
    }

    /// Adds `entry` first. The same schedule JSON dropped again for the same reason (a file that is never saved over
    /// is read on every launch) is not added twice. Then trimmed.
    public mutating func add(_ entry: DeletedSchedule, now: Date = Date()) {
        if entry.reason == .dropped,
           deleted.contains(where: { $0.reason == .dropped && $0.schedule == entry.schedule }) {
            trim(now: now)
            return
        }
        deleted.insert(entry, at: 0)
        trim(now: now)
    }

    /// Newest first, none older than `retention`, at most `maxEntries`.
    public mutating func trim(now: Date = Date()) {
        deleted = Array(deleted
            .filter { now.timeIntervalSince($0.deletedAt) <= Self.retention }
            .sorted { $0.deletedAt > $1.deletedAt }
            .prefix(Self.maxEntries))
    }

    /// The newest entry for schedule `id`.
    public func index(of id: String) -> Int? {
        deleted.indices.filter { deleted[$0].id == id }.max { deleted[$0].deletedAt < deleted[$1].deletedAt }
    }
}

/// Result of `schedule.deleted`.
public struct DeletedScheduleList: Codable, Equatable, Sendable {
    public var deleted: [DeletedSchedule]

    public init(deleted: [DeletedSchedule]) { self.deleted = deleted }
}
