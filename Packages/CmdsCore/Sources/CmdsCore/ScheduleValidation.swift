import Foundation

/// Something wrong with a schedule. `english` for the API and CLI; the app localizes its own text.
public enum ScheduleProblem: Equatable, Sendable {
    case nameInvalid
    case tooManySchedules
    case onceInPast
    case noWeekdays
    case timesCount
    case timesTooClose
    case unknownTimeZone(String)
    case delayOutOfRange
    case lateOutOfRange
    /// The editor's late field is not a number.
    case lateNotANumber
    case accountInvalid(String)
    case accountUnknown(String)
    case accountNotLimited(String)
    case noAccounts
    case folderInvalid
    case titleInvalid
    case commandInvalid
    case promptWithoutCommand
    case promptInvalid
    case promptTooLong
    case agentUnsupported
    case sessionIDInvalid
    /// A Codex session with an account (cmds has Claude accounts only).
    case accountWithCodex
    /// `codexLimitReset` (once) while Codex has no limit, or none is known.
    case codexNotLimited
    /// `sendText`: a stored target that is not a tag or a workspace title, or a pane that cannot be targeted.
    case targetInvalid

    public var english: String {
        switch self {
        case .nameInvalid: return "the name must be 1 to \(ScheduleLimits.maxNameLength) characters without control characters"
        case .tooManySchedules: return "at most \(ScheduleLimits.maxSchedules) schedules"
        case .onceInPast: return "the time has already passed"
        case .noWeekdays: return "choose at least one weekday"
        case .timesCount: return "give 1 to \(ScheduleLimits.maxTimesPerDay) times of day"
        case .timesTooClose: return "times of day must be at least \(Int(ScheduleLimits.minTimeGap / 60)) minutes apart"
        case .unknownTimeZone(let zone): return "unknown time zone \(zone)"
        case .delayOutOfRange: return "the delay must be 0 to \(Int(ScheduleLimits.maxDelay / 60)) minutes"
        case .lateNotANumber: return "give the late window as a number of minutes"
        case .lateOutOfRange: return "a late run must be allowed for 1 minute to \(Int(ScheduleLimits.maxLateWindow / 86400)) days"
        case .accountInvalid(let name): return "\(name) is not a valid account name"
        case .accountUnknown(let name): return "no account named \(name)"
        case .accountNotLimited(let name): return "account \(name) has no limit now"
        case .noAccounts: return "no accounts (cmds accounts add NAME DIR)"
        case .folderInvalid: return "the folder must be an absolute path or start with ~/"
        case .titleInvalid: return "the title must be at most \(ScheduleLimits.maxTitleLength) characters without control characters"
        case .commandInvalid: return "the command must be one line of at most \(ScheduleLimits.maxCommandBytes / 1024) KB without control characters"
        case .promptWithoutCommand: return "a prompt needs a command that starts Claude Code"
        case .promptInvalid: return "the prompt must not be empty or contain control characters other than line breaks and tabs"
        case .promptTooLong: return "the prompt must be at most \(ScheduleLimits.maxPromptBytes / 1024) KB"
        case .agentUnsupported: return "only Claude Code and Codex sessions can be continued"
        case .sessionIDInvalid: return "the session id is not valid"
        case .accountWithCodex: return "a Codex session has no account"
        case .codexNotLimited: return "Codex has no limit now"
        case .targetInvalid: return "the target must be a local terminal pane or a workspace title"
        }
    }
}

public enum ScheduleValidation {
    /// Problems of the schedule itself, independent of accounts and time. A stored schedule with any is dropped.
    public static func problems(_ draft: ScheduleDraft) -> [ScheduleProblem] {
        var problems: [ScheduleProblem] = []
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || draft.name.count > ScheduleLimits.maxNameLength || hasControlCharacters(draft.name) {
            problems.append(.nameInvalid)
        }
        switch draft.trigger {
        case .once:
            break
        case .weekly(let rule):
            if rule.weekdays.isEmpty { problems.append(.noWeekdays) }
            if !(1...ScheduleLimits.maxTimesPerDay).contains(rule.times.count) { problems.append(.timesCount) }
            if !timesApart(rule.times) { problems.append(.timesTooClose) }
            if let zone = rule.timeZone, TimeZone(identifier: zone) == nil { problems.append(.unknownTimeZone(zone)) }
        case .limitReset(let account, let delay, _):
            if ClaudeAccounts.nameProblem(account) != nil { problems.append(.accountInvalid(account)) }
            if !(0...ScheduleLimits.maxDelay).contains(delay) { problems.append(.delayOutOfRange) }
        case .codexLimitReset(let delay, _):
            if !(0...ScheduleLimits.maxDelay).contains(delay) { problems.append(.delayOutOfRange) }
        }
        if case .runIfWithin(let seconds) = draft.late, !(ScheduleLimits.minLateWindow...ScheduleLimits.maxLateWindow).contains(seconds) {
            problems.append(.lateOutOfRange)
        }
        switch draft.action {
        case .startWorkspace(let action):
            if !isFolder(action.cwd) { problems.append(.folderInvalid) }
            if let title = action.title, title.count > ScheduleLimits.maxTitleLength || hasControlCharacters(title) {
                problems.append(.titleInvalid)
            }
            if let account = action.account, account.lowercased() != ClaudeAccounts.automatic,
               ClaudeAccounts.nameProblem(account) != nil {
                problems.append(.accountInvalid(account))
            }
            if let command = action.command, !isCommand(command) { problems.append(.commandInvalid) }
            if let prompt = action.prompt {
                if action.command == nil { problems.append(.promptWithoutCommand) }
                problems += promptProblems(prompt)
            }
        case .continueSession(let action):
            if action.agent != .claude, action.agent != .codex { problems.append(.agentUnsupported) }
            if !AgentResume.isValidSessionID(action.sessionID) { problems.append(.sessionIDInvalid) }
            if let cwd = action.cwd, !isFolder(cwd) { problems.append(.folderInvalid) }
            if let account = action.account {
                if action.agent == .codex {
                    problems.append(.accountWithCodex)
                } else if ClaudeAccounts.nameProblem(account) != nil {
                    problems.append(.accountInvalid(account))
                }
            }
            problems += promptProblems(action.prompt)
        case .sendText(let action):
            if !isStoredTarget(action.target) { problems.append(.targetInvalid) }
            switch action.to {
            case .shell: if !isCommand(action.text) { problems.append(.commandInvalid) }
            case .agent: problems += promptProblems(action.text)
            }
        }
        return problems
    }

    /// A target as stored: a pane tag (`t` + 8 hex) or a workspace title of 1…64 characters on one line.
    static func isStoredTarget(_ target: PaneTarget) -> Bool {
        switch target {
        case .tag(let tag): return ScheduleIDs.isValid(tag, prefix: ScheduleIDs.paneTagPrefix)
        case .workspace(let title):
            let trimmed = title.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && title.count <= ScheduleLimits.maxTitleLength && !hasControlCharacters(title)
        case .pane: return false
        }
    }

    /// Whether a change is checked with `problems(_:accounts:existing:now:)` in full (also a time that is still ahead
    /// and an account limit): a new schedule (`old` nil), a new trigger, or turning it on. Other edits of a schedule
    /// whose time has passed are fine. The editor and the runner use this one rule.
    public static func needsFullCheck(old: ScheduleDraft?, new: ScheduleDraft) -> Bool {
        guard let old else { return true }
        return new.trigger != old.trigger || (new.enabled && !old.enabled)
    }

    /// Everything checked when a schedule is created or changed: `problems(_:)` plus the accounts it names, a time
    /// that is still ahead, an account limit for `limitReset`, and the number of schedules (`existing`, without this
    /// one).
    public static func problems(_ draft: ScheduleDraft, accounts: [ClaudeAccount], codex: AgentLimits? = nil,
                                existing: Int, now: Date = Date()) -> [ScheduleProblem] {
        var problems = problems(draft)
        if existing >= ScheduleLimits.maxSchedules { problems.append(.tooManySchedules) }
        func checkAccount(_ name: String?) {
            guard let name else { return }
            if name.lowercased() == ClaudeAccounts.automatic {
                if accounts.isEmpty { problems.append(.noAccounts) }
                return
            }
            // An invalid name is already reported.
            if ClaudeAccounts.nameProblem(name) == nil, !accounts.contains(where: { $0.hasName(name) }) {
                problems.append(.accountUnknown(name))
            }
        }
        switch draft.trigger {
        case .once(let at):
            if at <= now { problems.append(.onceInPast) }
        case .weekly:
            break
        case .limitReset(let account, _, let repeats):
            if ClaudeAccounts.nameProblem(account) == nil {
                if let found = accounts.first(where: { $0.hasName(account) }) {
                    // "Every time it resets" does not need a limit now.
                    if !repeats, !found.isLimited(at: now) { problems.append(.accountNotLimited(found.name)) }
                } else {
                    problems.append(.accountUnknown(account))
                }
            }
        case .codexLimitReset(_, let repeats):
            if !repeats, !(codex?.exhaustedReset.map { $0 > now } ?? false) { problems.append(.codexNotLimited) }
        }
        switch draft.action {
        case .startWorkspace(let action): checkAccount(action.account)
        case .continueSession(let action):
            // `auto` is not an account for a session (already reported as invalid); Codex has none.
            if action.agent == .claude, action.account?.lowercased() != ClaudeAccounts.automatic { checkAccount(action.account) }
        case .sendText:
            break
        }
        return problems
    }

    /// Any control character (names, titles, commands, folders).
    static func hasControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { isControl($0) || $0 == "\u{2028}" || $0 == "\u{2029}" }
    }

    /// C0 and C1 control characters and DEL.
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }

    /// Absolute or `~/…`, without control characters.
    static func isFolder(_ path: String) -> Bool {
        (path.hasPrefix("/") || path == "~" || path.hasPrefix("~/")) && path.count <= ScheduleLimits.maxPathLength
            && !hasControlCharacters(path)
    }

    /// One line, at most 1 KB, no control characters, not blank.
    static func isCommand(_ command: String) -> Bool {
        !command.trimmingCharacters(in: .whitespaces).isEmpty && command.utf8.count <= ScheduleLimits.maxCommandBytes
            && !hasControlCharacters(command)
    }

    /// A prompt is pasted (bracketed paste): line breaks and tabs are fine; any other control character (ESC could end
    /// the paste early and type the rest as keys) is refused.
    static func promptProblems(_ prompt: String) -> [ScheduleProblem] {
        var problems: [ScheduleProblem] = []
        let invalid = prompt.unicodeScalars.contains { isControl($0) && $0 != "\n" && $0 != "\t" }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || invalid { problems.append(.promptInvalid) }
        if prompt.utf8.count > ScheduleLimits.maxPromptBytes { problems.append(.promptTooLong) }
        return problems
    }

    /// Sorted times at least `minTimeGap` apart, also from the last one of a day to the first of the next.
    static func timesApart(_ times: [TimeOfDay]) -> Bool {
        let minutes = times.map(\.minutes).sorted()
        let gap = Int(ScheduleLimits.minTimeGap / 60)
        for (a, b) in zip(minutes, minutes.dropFirst()) where b - a < gap { return false }
        if minutes.count > 1, let first = minutes.first, let last = minutes.last, first + 24 * 60 - last < gap { return false }
        return true
    }
}
