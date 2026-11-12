import Foundation

/// Web answers kept for a while (#248): the same question again ("明日の東京の天気は？" twice, or after a follow-up) is
/// answered at once instead of searching again. Keyed by the question as `AssistantText.key` folds it, the language
/// and the local day (so "today" and "tomorrow" never cross midnight); only answers, never failures; at most
/// `capacity`, the oldest dropped.
public struct AssistantWebCache: Equatable, Sendable {
    /// How long an answer is reused.
    public static let lifetime: TimeInterval = 600
    public static let capacity = 20

    private struct Entry: Equatable, Sendable {
        var key: String
        var answer: String
        var at: Date
    }

    private var entries: [Entry] = []

    public init() {}

    public static func key(_ question: String, language: String, now: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: now)
        return "\(language)|\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)|\(AssistantText.key(question))"
    }

    /// The answer to the same question within `lifetime`, if any.
    public func answer(_ question: String, language: String, now: Date, timeZone: TimeZone = .current) -> String? {
        let key = Self.key(question, language: language, now: now, timeZone: timeZone)
        return entries.last { $0.key == key && now.timeIntervalSince($0.at) < Self.lifetime && now >= $0.at }?.answer
    }

    public mutating func store(_ answer: String, for question: String, language: String, now: Date, timeZone: TimeZone = .current) {
        let key = Self.key(question, language: language, now: now, timeZone: timeZone)
        guard !AssistantText.key(question).isEmpty, !answer.isEmpty else { return }
        entries.removeAll { $0.key == key || now.timeIntervalSince($0.at) >= Self.lifetime }
        entries.append(Entry(key: key, answer: answer, at: now))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }
}
