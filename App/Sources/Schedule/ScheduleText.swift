import Foundation
import CmdsCore

/// Mac-only UI text for schedules (English and Japanese); what the phone shows too (reasons, states, causes,
/// triggers, times) is `ScheduleStrings` (Shared/Sources). CmdsCore keeps the API's and the CLI's English
/// (`ScheduleReason.english`, `ScheduleProblem.english`).
@MainActor
enum ScheduleText {
    /// One line for a notification or the history: `Skipped: the pane was running another program.`
    static func outcome(_ run: ScheduleRun) -> String {
        if run.state == .missed {
            return String(localized: "Did not run at \(ScheduleStrings.time(run.dueAt)): the Mac was asleep or cmds was not running.")
        }
        guard let reason = run.reason else { return ScheduleStrings.state(run.state) }
        return "\(ScheduleStrings.state(run.state)) — \(ScheduleStrings.reason(reason))"
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
        case .lateNotANumber: return String(localized: "Give the late window as a number of minutes.")
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
        case .agentUnsupported: return String(localized: "Only Claude Code and Codex sessions can be continued.")
        case .sessionIDInvalid: return String(localized: "Choose a session.")
        case .accountWithCodex: return String(localized: "A Codex session has no account.")
        case .codexNotLimited: return String(localized: "Codex has no limit now.")
        case .targetInvalid: return String(localized: "Choose a terminal pane or give a workspace title.")
        }
    }

    /// `Weekdays 09:00`, `When “work” resets (15:00) + 1 min`, `Once, Nov 4 02:00`.
    static func trigger(_ trigger: ScheduleTrigger, accounts: [ClaudeAccount]) -> String {
        var reset: Date?
        switch trigger {
        case .once, .weekly:
            break
        case .limitReset(let name, _, _):
            reset = accounts.first { $0.hasName(name) }?.limit.flatMap { $0.isActive() ? $0.resetsAt : nil }
        case .codexLimitReset:
            reset = AppController.shared.agentLimitsByKind[.codex]?.exhaustedReset.flatMap { $0 > Date() ? $0 : nil }
        }
        return ScheduleStrings.trigger(trigger, reset: reset)
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
        case .sendText(let send):
            let place = target(send.target)
            switch send.to {
            case .shell: return String(localized: "Type “\(short(send.text))” in \(place)")
            case .agent: return String(localized: "Send “\(short(send.text))” to the agent in \(place)")
            }
        }
    }

    /// `pane “Fix login” in “API”`, `workspace “API”`; a tag no pane has: `a closed pane`.
    static func target(_ target: PaneTarget) -> String {
        let controller = AppController.shared
        switch target {
        case .workspace(let title):
            return String(localized: "workspace “\(title)”")
        case .tag, .pane:
            guard case .pane(let id) = controller.resolveScheduleTarget(target), let pane = controller.pane(id: id),
                  let workspace = controller.workspace(id: pane.workspaceID) else { return String(localized: "a closed pane") }
            return String(localized: "a pane of “\(workspace.displayTitle)”")
        }
    }

    /// One line of at most 24 characters.
    static func short(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count > 24 ? String(line.prefix(23)) + "…" : line
    }

    static func origin(_ origin: ScheduleOrigin) -> String {
        switch origin {
        case .app: return String(localized: "Created in cmds")
        case .api(let pane?): return String(localized: "Created from the command line or an agent (pane \(pane))")
        case .api(nil): return String(localized: "Created from the command line or an agent")
        }
    }

    /// The sidebar's next-run line.
    struct NextRunHint: Equatable {
        var title: String
        var tooltip: String
    }

    /// How many next runs the sidebar's tooltip lists.
    private static let nextRunHintCount = 3

    /// The earliest next run of an enabled schedule (`Morning tests · 09:00`); the next three in the tooltip.
    static func nextRunHint(_ schedules: [Schedule], now: Date = Date()) -> NextRunHint? {
        let upcoming = schedules.filter(\.enabled).compactMap { schedule in schedule.nextFireAt.map { (schedule, $0) } }
            .sorted { $0.1 < $1.1 }.prefix(nextRunHintCount)
        guard let first = upcoming.first else { return nil }
        let lines = upcoming.map { "\(ScheduleStrings.time($0.1, now: now))  \($0.0.name)" }
        return NextRunHint(title: "\(first.0.name) · \(ScheduleStrings.time(first.1, now: now))",
                           tooltip: String(localized: "Next schedules (Window › Schedules):") + "\n" + lines.joined(separator: "\n"))
    }
}
