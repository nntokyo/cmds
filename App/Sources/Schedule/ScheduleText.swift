import Foundation
import CmdsCore

/// UI text for schedules (English and Japanese). CmdsCore keeps the API's and the CLI's English
/// (`ScheduleReason.english`, `ScheduleProblem.english`).
@MainActor
enum ScheduleText {
    static func reason(_ reason: ScheduleReason) -> String {
        switch reason {
        case .confirmed: return String(localized: "Claude Code started working on the prompt.")
        case .unconfirmed: return String(localized: "The prompt was sent, but Claude Code was not seen working.")
        case .commandTyped: return String(localized: "The command was typed.")
        case .workspaceOpened: return String(localized: "The workspace was opened.")
        case .previousRunActive: return String(localized: "The previous run was still active.")
        case .tooManyRuns: return String(localized: "Too many runs were active.")
        case .paneInUse: return String(localized: "Another run was using the pane.")
        case .allAccountsLimited: return String(localized: "Every account has hit its limit.")
        case .agentRunning: return String(localized: "An agent was running in the pane.")
        case .otherProgram: return String(localized: "The pane was running another program.")
        case .agentNotRunning: return String(localized: "Claude Code was no longer running in the pane.")
        case .differentSession: return String(localized: "The pane was running a different session.")
        case .movedToOtherAccount: return String(localized: "The session had moved to another account.")
        case .notClaude: return String(localized: "The agent in the pane is not Claude Code.")
        case .accountRemoved: return String(localized: "The account was removed.")
        case .accountStillLimited: return String(localized: "The account was still limited.")
        case .paneClosed: return String(localized: "The pane was closed.")
        case .shellNotReady: return String(localized: "The shell prompt did not become ready.")
        case .agentDidNotStart: return String(localized: "Claude Code did not start.")
        case .agentBusy: return String(localized: "Claude Code stayed busy.")
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
        case .waitingForAgent: return String(localized: "Waiting for Claude Code")
        case .confirming: return String(localized: "Confirming")
        case .succeeded: return String(localized: "Succeeded")
        case .failed: return String(localized: "Failed")
        case .skipped: return String(localized: "Skipped")
        case .missed: return String(localized: "Missed")
        case .cancelled: return String(localized: "Cancelled")
        }
    }

    /// One line for a notification or the history: `Skipped: the pane was running another program.`
    static func outcome(_ run: ScheduleRun) -> String {
        if run.state == .missed {
            return String(localized: "Did not run at \(time(run.dueAt)): the Mac was asleep or cmds was not running.")
        }
        guard let reason = run.reason else { return state(run.state) }
        return "\(state(run.state)) — \(self.reason(reason))"
    }

    static func cause(_ cause: ScheduleRun.Cause) -> String {
        switch cause {
        case .scheduled: return String(localized: "Scheduled")
        case .catchUp: return String(localized: "Catch-up")
        case .manual: return String(localized: "Run Now")
        }
    }

    /// A refused change: the runner's message (English, as for the API), else the error itself.
    static func error(_ error: Error) -> String {
        (error as? RPCError)?.message ?? "\(error)"
    }

    static func problem(_ problem: ScheduleProblem) -> String {
        switch problem {
        case .nameInvalid: return String(localized: "Give a name of up to 64 characters.")
        case .tooManySchedules: return String(localized: "There are already 50 schedules.")
        case .onceInPast: return String(localized: "The time has already passed.")
        case .noWeekdays: return String(localized: "Choose at least one weekday.")
        case .timesCount: return String(localized: "Give 1 to 24 times of day (HH:MM, separated by commas).")
        case .timesTooClose: return String(localized: "Times of day must be at least 5 minutes apart.")
        case .unknownTimeZone(let zone): return String(localized: "Unknown time zone “\(zone)”.")
        case .delayOutOfRange: return String(localized: "The delay must be 0 to 60 minutes.")
        case .lateOutOfRange: return String(localized: "A late run must be allowed for 1 minute to 7 days.")
        case .accountInvalid(let name): return String(localized: "“\(name)” is not a valid account name.")
        case .accountUnknown(let name): return String(localized: "There is no account named “\(name)”.")
        case .accountNotLimited(let name): return String(localized: "“\(name)” has no limit now.")
        case .noAccounts: return String(localized: "Add Claude accounts first (Settings › Agents).")
        case .folderInvalid: return String(localized: "Choose a folder (an absolute path or ~/…).")
        case .titleInvalid: return String(localized: "The title must be at most 64 characters on one line.")
        case .commandInvalid: return String(localized: "The command must be one line of at most 1 KB.")
        case .promptWithoutCommand: return String(localized: "A prompt needs a command that starts Claude Code.")
        case .promptInvalid: return String(localized: "The prompt must not be empty or contain control characters.")
        case .promptTooLong: return String(localized: "The prompt must be at most 8 KB.")
        case .agentUnsupported: return String(localized: "Only Claude Code sessions can be continued.")
        case .sessionIDInvalid: return String(localized: "Choose a Claude Code session.")
        }
    }

    /// `Weekdays 09:00`, `When “work” resets (15:00) + 1 min`, `Once, Nov 4 02:00`.
    static func trigger(_ trigger: ScheduleTrigger, accounts: [ClaudeAccount]) -> String {
        switch trigger {
        case .once(let at):
            return String(localized: "Once, \(time(at))")
        case .weekly(let rule):
            let times = rule.times.map(\.text).joined(separator: String(localized: ", ", comment: "list separator"))
            var text = "\(days(rule.weekdays)) \(times)"
            if let zone = rule.timeZone { text += " (\(zone))" }
            return text
        case .limitReset(let name, let delay):
            let reset = accounts.first { $0.hasName(name) }?.limit.flatMap { $0.isActive() ? time($0.resetsAt) : nil }
            let minutes = Int((delay / 60).rounded())
            switch (reset, minutes > 0) {
            case (let reset?, true): return String(localized: "When “\(name)” resets (\(reset)) + \(minutes) min")
            case (let reset?, false): return String(localized: "When “\(name)” resets (\(reset))")
            case (nil, true): return String(localized: "When “\(name)” resets + \(minutes) min")
            case (nil, false): return String(localized: "When “\(name)” resets")
            }
        }
    }

    static func days(_ weekdays: Set<Weekday>) -> String {
        if weekdays == Set(Weekday.allCases) { return String(localized: "Every day") }
        if weekdays == Weekday.workdays { return String(localized: "Weekdays") }
        if weekdays == [.sat, .sun] { return String(localized: "Weekends") }
        let formatter = DateFormatter()
        let symbols = formatter.shortWeekdaySymbols ?? []
        return weekdays.sorted().compactMap { symbols[safe: $0.calendarWeekday - 1] }.joined(separator: " ")
    }

    /// `Start “app”: claude + prompt`, `Continue “Fix login”`.
    static func action(_ action: ScheduleAction) -> String {
        switch action {
        case .startWorkspace(let start):
            let folder = (start.cwd as NSString).lastPathComponent
            guard let command = start.command else { return String(localized: "Open “\(folder)”") }
            return start.prompt == nil ? String(localized: "Start “\(folder)”: \(command)")
                : String(localized: "Start “\(folder)”: \(command) + prompt")
        case .continueSession(let session):
            let known = AppController.shared.workspaces.flatMap(\.orderedPanes)
                .compactMap { $0.agentSession ?? $0.resumeOffer }.first { $0.sessionID == session.sessionID }
            if let title = AgentResume.cleanTitle(known?.title) { return String(localized: "Continue “\(title)”") }
            return String(localized: "Continue session \(String(session.sessionID.prefix(8)))")
        }
    }

    static func origin(_ origin: ScheduleOrigin) -> String {
        switch origin {
        case .app: return String(localized: "Created in cmds")
        case .api(let pane?): return String(localized: "Created from the command line or an agent (pane \(pane))")
        case .api(nil): return String(localized: "Created from the command line or an agent")
        }
    }

    /// `15:00` today, `Thu 09:00` this week, else `Nov 12 09:00`.
    static func time(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if abs(date.timeIntervalSince(now)) < 6 * 86400 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
