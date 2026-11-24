import Foundation

/// What a Claude Code session is told after cmds resumed it: after cmds restarted (#440) or after an account switch
/// moved it to another account. A resumed Claude Code waits at its prompt, and the scheduled jobs it made in the
/// session (`CronCreate`, a `/loop`'s `ScheduleWakeup`) died with the old process, so without this note the work stops
/// until someone types. Nothing is said when there is nothing to say (an idle session without jobs after a restart).
public enum ResumeNote {
    public enum Reason: Equatable, Sendable {
        case restart
        case accountSwitch(from: String, to: String)
    }

    /// A job the session scheduled that is gone with its process.
    public struct Job: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// `CronCreate`, recurring, session-only.
            case cron(String)
            /// A `/loop` waiting for its next `ScheduleWakeup`.
            case loop
        }

        public var kind: Kind
        /// Its prompt, at most `maxPromptCharacters`.
        public var prompt: String

        public init(kind: Kind, prompt: String) {
            self.kind = kind
            self.prompt = prompt
        }
    }

    public static let maxPromptCharacters = 200
    public static let maxJobs = 5

    /// The note, one line; nil when there is nothing to say.
    public static func prompt(reason: Reason, cutOff: Bool, jobs: [Job]) -> String? {
        var parts: [String] = []
        switch reason {
        case .restart:
            guard cutOff || !jobs.isEmpty else { return nil }
            parts.append(cutOff ? "cmds was restarted while you were working. Continue where you left off."
                                : "cmds was restarted, and this session was resumed.")
        case .accountSwitch(let from, let to):
            parts.append("cmds moved this session to the Claude account “\(to)” because “\(from)” hit its limit. Continue where you left off.")
        }
        let shown = jobs.prefix(maxJobs)
        let crons = shown.compactMap { job -> String? in
            guard case .cron(let schedule) = job.kind else { return nil }
            return "`\(schedule)`: “\(oneLine(job.prompt))”"
        }
        if !crons.isEmpty {
            parts.append("Your scheduled jobs ended with the old Claude Code process (they lived only in the session): create them again with CronCreate as before ("
                         + crons.joined(separator: "; ") + "), then check them with CronList. "
                         + "A job that should outlive restarts can be a cmds schedule instead, which types its prompt into this pane: "
                         + "`cmds schedule add --name NAME --every 5m --send PROMPT --to agent`.")
        }
        if shown.contains(where: { $0.kind == .loop }) {
            parts.append("Your /loop was waiting for its next wake-up, which is gone: schedule it again with ScheduleWakeup as before.")
        }
        return parts.joined(separator: " ")
    }

    static func oneLine(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > maxPromptCharacters ? String(flat.prefix(maxPromptCharacters)) + "…" : flat
    }

    // MARK: Jobs from the transcript

    /// Recurring session-only `CronCreate` jobs not cancelled (`CronDelete`) nor expired (7 days), and a `/loop` whose
    /// last `ScheduleWakeup` (within a day) did not stop it. `lines`: the transcript's lines that mention them
    /// (`scan` picks them out of a large file).
    public static func jobs(transcriptLines lines: [Substring], now: Date) -> [Job] {
        var pending: [String: (schedule: String, prompt: String, recurring: Bool)] = [:]  // tool_use id → CronCreate
        var crons: [(id: String, schedule: String, prompt: String, at: Date)] = []
        var cancelled = Set<String>()
        var lastWakeup: (prompt: String, stop: Bool, at: Date)?
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in lines {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = entry["message"] as? [String: Any], let items = message["content"] as? [[String: Any]] else { continue }
            let at = (entry["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? now
            for item in items {
                switch item["type"] as? String {
                case "tool_use":
                    let input = item["input"] as? [String: Any] ?? [:]
                    switch item["name"] as? String {
                    case "CronCreate":
                        guard let id = item["id"] as? String, let schedule = input["cron"] as? String else { break }
                        let durable = input["durable"] as? Bool == true
                        pending[id] = durable ? nil : (schedule, input["prompt"] as? String ?? "", input["recurring"] as? Bool ?? true)
                    case "CronDelete":
                        if let id = input["id"] as? String { cancelled.insert(id) }
                    case "ScheduleWakeup":
                        lastWakeup = (input["prompt"] as? String ?? "", input["stop"] as? Bool == true, at)
                    default:
                        break
                    }
                case "tool_result":
                    guard let use = item["tool_use_id"] as? String, let created = pending.removeValue(forKey: use) else { break }
                    let text = (item["content"] as? String)
                        ?? (item["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: " ") ?? ""
                    // "Scheduled recurring job 89b1ef41 (…). … Session-only (not written to disk, …)"
                    guard created.recurring, text.contains("Session-only"),
                          let range = text.range(of: #"job ([0-9a-f]{4,})"#, options: .regularExpression) else { break }
                    let id = String(text[range].dropFirst(4))
                    crons.append((id, created.schedule, created.prompt, at))
                default:
                    break
                }
            }
        }
        let week: TimeInterval = 7 * 86400
        // The same schedule and prompt once: a job made again after an earlier restart (the old one died without a
        // CronDelete) must not come back twice.
        var seen = Set<String>()
        var result = crons.filter { !cancelled.contains($0.id) && now.timeIntervalSince($0.at) < week }
            .reversed().filter { seen.insert($0.schedule + "\u{1}" + $0.prompt).inserted }.reversed()
            .map { Job(kind: .cron($0.schedule), prompt: $0.prompt) }
        if let wake = lastWakeup, !wake.stop, now.timeIntervalSince(wake.at) < 86400 {
            result.append(Job(kind: .loop, prompt: wake.prompt))
        }
        return result
    }

    /// The lines of the transcript at `path` that mention scheduled jobs, read in chunks (transcripts reach 100 MB).
    public static func jobLines(path: String) -> [Substring] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let needles = ["CronCreate", "CronDelete", "ScheduleWakeup", "Scheduled recurring job"].map { Data($0.utf8) }
        var lines: [Substring] = []
        var carry = Data()
        while true {
            let chunk = handle.readData(ofLength: 4 * 1024 * 1024)
            if chunk.isEmpty { break }
            var data = carry + chunk
            guard let lastNewline = data.lastIndex(of: 0x0A) else { carry = data; continue }
            carry = data.subdata(in: data.index(after: lastNewline)..<data.endIndex)
            data = data.subdata(in: data.startIndex..<data.index(after: lastNewline))
            guard needles.contains(where: { data.range(of: $0) != nil }) else { continue }
            for line in data.split(separator: 0x0A) where needles.contains(where: { line.range(of: $0) != nil }) {
                lines.append(Substring(String(decoding: line, as: UTF8.self)))
            }
        }
        return lines
    }
}
