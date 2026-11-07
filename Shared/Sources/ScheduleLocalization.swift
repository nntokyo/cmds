import CmdsCore
import Foundation

// UI text for schedules shared by the Mac (Window › Schedules) and the phone's read-only list (#45 phase 3), so both
// catalogs have the same keys. CmdsCore keeps the API's and the CLI's English (`ScheduleReason.english`).

enum ScheduleStrings {
    static func reason(_ reason: ScheduleReason) -> String {
        switch reason {
        case .confirmed: return String(localized: "The agent started working on the prompt.")
        case .unconfirmed: return String(localized: "The prompt was sent, but the agent was not seen working.")
        case .commandTyped: return String(localized: "The command was typed.")
        case .workspaceOpened: return String(localized: "The workspace was opened.")
        case .previousRunActive: return String(localized: "The previous run was still active.")
        case .tooManyRuns: return String(localized: "Too many runs were active.")
        case .paneInUse: return String(localized: "Another run was using the pane.")
        case .allAccountsLimited: return String(localized: "Every account has hit its limit.")
        case .agentRunning: return String(localized: "An agent was running in the pane.")
        case .otherProgram: return String(localized: "The pane was running another program.")
        case .agentNotRunning: return String(localized: "No agent was running in the pane.")
        case .differentSession: return String(localized: "The pane was running a different session.")
        case .ambiguousSession: return String(localized: "Several panes hold the session.")
        case .movedToOtherAccount: return String(localized: "The session had moved to another account.")
        case .notClaude: return String(localized: "The agent in the pane is not Claude Code.")
        case .notCodex: return String(localized: "The agent in the pane is not Codex.")
        case .paneNotFound: return String(localized: "The target pane was not found.")
        case .ambiguousTarget: return String(localized: "Several panes match the target.")
        case .skippedByUser: return String(localized: "Skipped on request.")
        case .accountRemoved: return String(localized: "The account was removed.")
        case .accountStillLimited: return String(localized: "The account was still limited.")
        case .paneClosed: return String(localized: "The pane was closed.")
        case .shellNotReady: return String(localized: "The shell prompt did not become ready.")
        case .agentDidNotStart: return String(localized: "The agent did not start.")
        case .agentBusy: return String(localized: "The agent stayed busy.")
        case .sessionNotFound: return String(localized: "No pane holds the session, and its folder is not known.")
        case .folderMissing: return String(localized: "The folder does not exist.")
        case .invalidSchedule: return String(localized: "The schedule is not valid any more.")
        case .resumeNotPossible: return String(localized: "The session cannot be resumed.")
        case .missed: return String(localized: "The Mac was asleep or cmds was not running.")
        case .cancelledByUser: return String(localized: "Cancelled.")
        case .scheduleRemoved: return String(localized: "The schedule was removed.")
        case .appQuit: return String(localized: "cmds quit during the run.")
        case .other: return String(localized: "Unknown reason.")
        }
    }

    static func state(_ state: ScheduleRunState) -> String {
        switch state {
        case .waitingForAccount: return String(localized: "Waiting for the account")
        case .waitingForPane: return String(localized: "Waiting for the shell")
        case .typing: return String(localized: "Typing")
        case .waitingForAgent: return String(localized: "Waiting for the agent")
        case .confirming: return String(localized: "Confirming")
        case .succeeded: return String(localized: "Succeeded")
        case .failed: return String(localized: "Failed")
        case .skipped: return String(localized: "Skipped")
        case .missed: return String(localized: "Missed")
        case .cancelled: return String(localized: "Cancelled")
        }
    }

    static func cause(_ cause: ScheduleRun.Cause) -> String {
        switch cause {
        case .scheduled: return String(localized: "Scheduled")
        case .catchUp: return String(localized: "Catch-up")
        case .manual: return String(localized: "Run Now")
        }
    }

    /// `Weekdays 09:00`, `When “work” resets (15:00) + 1 min`, `Once, Nov 4 02:00`. `reset`: the current limit's end
    /// of a limit trigger, when known.
    static func trigger(_ trigger: ScheduleTrigger, reset: Date? = nil, now: Date = Date()) -> String {
        switch trigger {
        case .once(let at):
            return String(localized: "Once, \(time(at, now: now))")
        case .weekly(let rule):
            let times = rule.times.map(\.text).joined(separator: String(localized: ", ", comment: "list separator"))
            var text = "\(days(rule.weekdays)) \(times)"
            if let zone = rule.timeZone { text += " (\(zone))" }
            return text
        case .limitReset(let name, let delay, let repeats):
            let base = repeats ? String(localized: "Every time “\(name)” resets") : String(localized: "When “\(name)” resets")
            return limitText(base, reset: reset.map { time($0, now: now) }, delay: delay)
        case .codexLimitReset(let delay, let repeats):
            let base = repeats ? String(localized: "Every time Codex resets") : String(localized: "When Codex resets")
            return limitText(base, reset: reset.map { time($0, now: now) }, delay: delay)
        }
    }

    /// `When “work” resets (15:00) + 1 min`.
    private static func limitText(_ base: String, reset: String?, delay: TimeInterval) -> String {
        let minutes = Int((delay / 60).rounded())
        var text = base
        if let reset { text += " (\(reset))" }
        if minutes > 0 { text += String(localized: " + \(minutes) min") }
        return text
    }

    static func days(_ weekdays: Set<Weekday>) -> String {
        if weekdays == Set(Weekday.allCases) { return String(localized: "Every day") }
        if weekdays == Weekday.workdays { return String(localized: "Weekdays") }
        if weekdays == [.sat, .sun] { return String(localized: "Weekends") }
        let symbols = DateFormatter().shortWeekdaySymbols ?? []
        return weekdays.sorted().compactMap { day in
            symbols.indices.contains(day.calendarWeekday - 1) ? symbols[day.calendarWeekday - 1] : nil
        }.joined(separator: " ")
    }

    /// `15:00` today, `Thu 09:00` this week, else `Nov 12 09:00`.
    static func time(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if abs(date.timeIntervalSince(now)) < 6 * 86400 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
