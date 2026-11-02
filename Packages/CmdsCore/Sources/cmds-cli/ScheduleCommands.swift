import CmdsCore
import Foundation

// `cmds schedule …`: schedules that start a workspace, continue a Claude Code or Codex session, or type into a pane
// later (docs/guide/schedules.md, docs/reference/cli.md). Times are parsed here, in the Mac's zone, and sent as epoch seconds.
extension CLI {
    static let scheduleUsage = """
        schedule add --name NAME TRIGGER ACTION [--late skip|MINUTES] [--notify failures|always|never] [--no-warn] [--disabled]
          TRIGGER  --at "YYYY-MM-DD HH:MM" | --at HH:MM | --in 90m
                   --every weekdays|daily|weekends|mon,wed,fri --time 09:00[,13:30] [--tz Asia/Tokyo]
                   --after-limit ACCOUNT | --after-codex-limit  [--delay 2m] [--repeat]
          ACTION   --start DIR [--account NAME|auto] [--title T] [--prompt TEXT|-] [-- command…]
                   --continue [--pane P | --session ID] [--account NAME] [--prompt TEXT|-]
                   --send TEXT|- --to shell|agent [--pane P | --workspace TITLE]
        """

    static let scheduleCommands: [Command] = [
        Command(name: "schedule", usage: "schedule [list]",
                summary: "List schedules: when they run next and how the last run ended.",
                details: """
                    Schedules start a workspace, continue a Claude Code or Codex session, or type into a pane at a
                    time, on weekdays, or when a limit resets; they run while cmds runs. `cmds schedule add --help` for the options.
                    See docs/guide/schedules.md.
                    """) { ctx in
            try ctx.args.expectPositionals(0...1, usage: "cmds schedule [list]")
            if let word = ctx.args.positionals.first, word != "list" {
                throw CLIError.usage("unknown subcommand: \(word)\n" + groupHelp("schedule"))
            }
            try listSchedules(ctx)
        },
        Command(name: "schedule list", usage: "schedule list", summary: "Same as `cmds schedule`.") { ctx in
            try ctx.args.expectPositionals(0...0, usage: "cmds schedule list")
            try listSchedules(ctx)
        },
        Command(name: "schedule add", usage: scheduleUsage.components(separatedBy: "\n")[0].trimmingCharacters(in: .whitespaces),
                summary: "Add a schedule.",
                details: scheduleUsage + "\n\n" + """
                    --at is a local date and time (or the next HH:MM); --in a delay (90m, 2h, 1h30m, 45s).
                    --every runs on those weekdays at each --time (5 minutes apart at least), in --tz or the Mac's zone.
                    --after-limit runs once when the Claude account's current limit resets, plus --delay (default 1m);
                    --after-codex-limit when Codex's limit resets. With --repeat: every time a limit resets.
                    --start opens a new background workspace in DIR (never selected) and types the command at its
                    prompt; --prompt is pasted into the Claude Code that command starts, once it is idle.
                    --continue sends --prompt (default "continue") to a remembered Claude Code or Codex session: the one
                    in --pane (default: this pane) or --session. If the session is not running it is resumed first.
                    --send types TEXT into an existing pane (--pane, default this pane; it keeps a tag, so the
                    schedule finds it after cmds restarts) or the only terminal pane of the workspace titled --workspace:
                    --to shell types it as a command at an empty shell prompt; --to agent pastes it into Claude Code or
                    Codex once it is idle. Otherwise the run is skipped.
                    A notification "starts in 1 minute" with Skip comes before each run (--no-warn: none).
                    --late: what to do when the time passed while the Mac slept or cmds was not running: skip, or run
                    when at most MINUTES late (default 360 for one-time schedules, 15 for weekly ones).
                    Nothing is typed into a busy agent, a pane running another program, or a pane the schedule did not
                    create or target. Examples:
                      cmds schedule add --name "Continue after reset" --after-limit work --continue
                      cmds schedule add --name bench --at "2026-11-04 02:00" --start ~/src/app -- make bench
                      cmds schedule add --name "Codex goes on" --after-codex-limit --repeat --send continue --to agent
                    """,
                options: scheduleValueOptions, flags: scheduleFlags) { ctx in
            try ctx.args.expectPositionals(0...0, usage: "cmds schedule add --name NAME TRIGGER ACTION (see --help)")
            let options = try parseScheduleOptions(ctx)
            guard let name = options.name else { throw CLIError.usage("--name is required") }
            guard let trigger = options.trigger else {
                throw CLIError.usage("give a trigger: --at, --in, --every or --after-limit")
            }
            guard let action = try scheduleAction(options, ctx: ctx) else {
                throw CLIError.usage("give an action: --start DIR, --continue or --send TEXT")
            }
            var draft: [String: JSONValue] = ["name": .string(name), "trigger": trigger, "action": action]
            if let late = options.late { draft["late"] = late }
            if let notify = options.notify { draft["notify"] = .string(notify) }
            if let enabled = options.enabled { draft["enabled"] = .bool(enabled) }
            if let warn = options.warn { draft["warn"] = .bool(warn) }
            let result = try ctx.call("schedule.add", ["schedule": .object(draft), "pane": ctx.envPane.json])
            try printEntry(result, ctx)
        },
        Command(name: "schedule edit", usage: "schedule edit <id> [add options]",
                summary: "Change a schedule: a trigger option replaces the trigger, an action option the action.",
                details: scheduleUsage + "\n  --enabled turns it on, --warn turns the notice on.", options: scheduleValueOptions,
                flags: scheduleFlags.union(["enabled", "warn"])) { ctx in
            try ctx.args.expectPositionals(1...1, usage: "cmds schedule edit <id> [add options]")
            let options = try parseScheduleOptions(ctx)
            var params: [String: JSONValue?] = ["id": .string(ctx.args.positionals[0])]
            params["name"] = options.name.json
            params["trigger"] = options.trigger
            params["action"] = try scheduleAction(options, ctx: ctx)
            params["late"] = options.late
            params["notify"] = options.notify.json
            params["enabled"] = ctx.args.has("enabled") ? .bool(true) : options.enabled.map { .bool($0) }
            params["warn"] = ctx.args.has("warn") ? .bool(true) : options.warn.map { .bool($0) }
            guard params.values.compactMap({ $0 }).count > 1 else { throw CLIError.usage("nothing to change") }
            let result = try ctx.call("schedule.update", params)
            try printEntry(result, ctx)
        },
        Command(name: "schedule show", usage: "schedule show <id>", summary: "Show a schedule, its next run and its last runs.") { ctx in
            try ctx.args.expectPositionals(1...1, usage: "cmds schedule show <id>")
            let id = ctx.args.positionals[0]
            let list = try perform { try ctx.call("schedule.list").decode(ScheduleList.self) }
            guard let entry = list.schedules.first(where: { $0.schedule.id == id }) else {
                throw CLIError.failure("schedule not found: \(id)")
            }
            let history = try perform {
                try ctx.call("schedule.history", ["id": .string(id), "limit": .number(Double(showRunsLimit))]).decode(ScheduleHistoryList.self)
            }
            if ctx.json { return ctx.printJSON(try .from(entry)) }
            print(Format.scheduleDetails(entry, runs: history.runs), terminator: "")
        },
        Command(name: "schedule enable", usage: "schedule enable <id>", summary: "Turn a schedule on.") { ctx in
            try setScheduleEnabled(ctx, true)
        },
        Command(name: "schedule disable", usage: "schedule disable <id>", summary: "Turn a schedule off (an active run goes on).") { ctx in
            try setScheduleEnabled(ctx, false)
        },
        Command(name: "schedule remove", usage: "schedule remove <id>",
                summary: "Remove a schedule. Its active run is cancelled; its history is kept.") { ctx in
            try ctx.args.expectPositionals(1...1, usage: "cmds schedule remove <id>")
            let result = try ctx.call("schedule.remove", ["id": .string(ctx.args.positionals[0])])
            if ctx.json { return ctx.printJSON(result) }
        },
        Command(name: "schedule run", usage: "schedule run <id>", summary: "Run a schedule now (also when it is off).") { ctx in
            try ctx.args.expectPositionals(1...1, usage: "cmds schedule run <id>")
            let result = try ctx.call("schedule.run", ["id": .string(ctx.args.positionals[0])])
            if ctx.json { return ctx.printJSON(result) }
            let run = try perform { try result["run"]?.decode(ScheduleRun.self) }
            if let run { print(Format.scheduleRun(run)) }
        },
        Command(name: "schedule skip", usage: "schedule skip <id>",
                summary: "Skip a schedule's next run (as the notice's Skip does); a one-time schedule is turned off.") { ctx in
            try ctx.args.expectPositionals(1...1, usage: "cmds schedule skip <id>")
            let result = try ctx.call("schedule.skip", ["id": .string(ctx.args.positionals[0])])
            if ctx.json { return ctx.printJSON(result) }
            let run = try perform { try result["run"]?.decode(ScheduleRun.self) }
            if let run { print(Format.scheduleRun(run)) }
        },
        Command(name: "schedule cancel", usage: "schedule cancel <run>", summary: "Cancel an active run (nothing more is typed).") { ctx in
            try ctx.args.expectPositionals(1...1, usage: "cmds schedule cancel <run>")
            let result = try ctx.call("schedule.cancel", ["run": .string(ctx.args.positionals[0])])
            if ctx.json { return ctx.printJSON(result) }
        },
        Command(name: "schedule history", usage: "schedule history [id] [--limit N]",
                summary: "Show past runs, newest first (default \(ScheduleLimits.defaultHistoryLimit), at most \(ScheduleLimits.maxRuns)).", options: ["limit"]) { ctx in
            try ctx.args.expectPositionals(0...1, usage: "cmds schedule history [id] [--limit N]")
            let result = try ctx.call("schedule.history", ["id": ctx.args.positionals.first.json,
                                                           "limit": try ctx.args.int("limit").map { .number(Double($0)) }])
            if ctx.json { return ctx.printJSON(result) }
            let history = try perform { try result.decode(ScheduleHistoryList.self) }
            print(Format.scheduleHistory(history.runs), terminator: "")
        },
    ]

    static let scheduleValueOptions: Set<String> = [
        "name", "at", "in", "every", "time", "tz", "after-limit", "delay", "start", "account", "title", "prompt", "pane",
        "session", "late", "notify", "send", "to", "workspace",
    ]
    static let scheduleFlags: Set<String> = ["continue", "disabled", "after-codex-limit", "repeat", "no-warn"]
    /// Last runs in `schedule show`.
    private static let showRunsLimit = 5

    private static func listSchedules(_ ctx: Context) throws {
        let result = try ctx.call("schedule.list")
        if ctx.json { return ctx.printJSON(result) }
        print(Format.schedules(try perform { try result.decode(ScheduleList.self) }), terminator: "")
    }

    private static func setScheduleEnabled(_ ctx: Context, _ enabled: Bool) throws {
        try ctx.args.expectPositionals(1...1, usage: "cmds schedule \(enabled ? "enable" : "disable") <id>")
        let result = try ctx.call("schedule.update", ["id": .string(ctx.args.positionals[0]), "enabled": .bool(enabled)])
        try printEntry(result, ctx)
    }

    /// A schedule as `schedule.add` / `schedule.update` return it: one line (or the JSON).
    private static func printEntry(_ result: JSONValue, _ ctx: Context) throws {
        if ctx.json { return ctx.printJSON(result) }
        print(Format.scheduleAdded(try perform { try result.decode(ScheduleListEntry.self) }), terminator: "")
    }

    /// The action from the options: `--start` as parsed, `--continue` with the session looked up in `agent.sessions`,
    /// `--send` with this pane when no target is given.
    private static func scheduleAction(_ options: ScheduleOptions, ctx: Context) throws -> JSONValue? {
        if let start = options.start { return start }
        if let send = options.send {
            return try sendAction(send, envPane: ctx.envPane)
        }
        guard let target = options.continueTarget else { return nil }
        let pane: String?
        switch target {
        case .pane(let id): pane = id
        case .session: pane = nil
        case .current:
            guard let current = ctx.envPane else {
                throw CLIError.usage("--continue needs --pane P or --session ID outside a cmds terminal")
            }
            pane = current
        }
        let sessions = try perform { try ctx.call("agent.sessions", ["pane": pane.json]).decode(AgentSessionList.self) }
        return try continueAction(target: target, pane: pane, sessions: sessions, account: options.account,
                                  prompt: options.prompt)
    }

    // MARK: Parsing (pure; CmdsCLITests)

    enum ContinueTarget: Equatable {
        /// This pane (`CMDS_PANE_ID`).
        case current
        case pane(String)
        case session(String)
    }

    /// `--send`: what and where (nil target: this pane).
    struct SendOptions: Equatable {
        var text: String
        var to: SendText.Destination
        var target: PaneTarget?
    }

    struct ScheduleOptions {
        var name: String?
        var trigger: JSONValue?
        /// A complete `startWorkspace` action.
        var start: JSONValue?
        var continueTarget: ContinueTarget?
        var send: SendOptions?
        var account: String?
        var prompt: String?
        var late: JSONValue?
        var notify: String?
        var enabled: Bool?
        var warn: Bool?
    }

    /// The options as typed now, in the Mac's zone and the current directory.
    private static func parseScheduleOptions(_ ctx: Context) throws -> ScheduleOptions {
        try parseScheduleOptions(ctx.args, now: Date(), timeZone: .current, cwd: FileManager.default.currentDirectoryPath,
                                 readStandardInput: readStandardInput)
    }

    static func parseScheduleOptions(_ args: Arguments, now: Date, timeZone: TimeZone, cwd: String,
                                     readStandardInput: () -> String) throws -> ScheduleOptions {
        var options = ScheduleOptions()
        options.name = args[option: "name"]
        if args.has("disabled") { options.enabled = false }
        if args.has("no-warn") { options.warn = false }
        options.notify = try args[option: "notify"].map { raw in
            guard ScheduleNotify(rawValue: raw) != nil else { throw CLIError.usage("--notify must be failures, always or never") }
            return raw
        }
        options.late = try args[option: "late"].map(parseLate)
        options.account = args[option: "account"]
        if let prompt = args[option: "prompt"] { options.prompt = prompt == "-" ? readStandardInput() : prompt }
        options.trigger = try parseTrigger(args, now: now, timeZone: timeZone)

        let start = args[option: "start"]
        let continuing = args.has("continue")
        let send = args[option: "send"]
        if [start != nil, continuing, send != nil].filter({ $0 }).count > 1 {
            throw CLIError.usage("give one of --start, --continue or --send")
        }
        if send == nil {
            for option in ["to", "workspace"] where args[option: option] != nil {
                throw CLIError.usage("--\(option) goes with --send")
            }
        }
        if let send {
            for option in ["account", "title", "prompt", "session"] where args[option: option] != nil {
                throw CLIError.usage("--\(option) does not go with --send")
            }
            if args.rest != nil { throw CLIError.usage("--send takes no command after --") }
            guard let raw = args[option: "to"] else { throw CLIError.usage("--send needs --to shell or --to agent") }
            guard let to = SendText.Destination(rawValue: raw) else { throw CLIError.usage("--to must be shell or agent") }
            let target: PaneTarget?
            switch (args[option: "pane"], args[option: "workspace"]) {
            case (let pane?, nil): target = .pane(pane)
            case (nil, let title?): target = .workspace(title: title)
            case (nil, nil): target = nil
            default: throw CLIError.usage("give either --pane or --workspace")
            }
            options.send = SendOptions(text: send == "-" ? readStandardInput() : send, to: to, target: target)
        } else if let start {
            if args[option: "pane"] != nil || args[option: "session"] != nil {
                throw CLIError.usage("--pane and --session go with --continue or --send")
            }
            var action: [String: JSONValue] = ["type": "startWorkspace", "cwd": .string(absolute(start, base: cwd))]
            action["title"] = args[option: "title"].json
            action["account"] = options.account.json
            action["command"] = shellCommand(args.rest ?? []).json
            action["prompt"] = options.prompt.json
            options.start = .object(action.compactMapValues { $0 == .null ? nil : $0 })
        } else if continuing {
            if args.rest != nil { throw CLIError.usage("--continue takes no command") }
            if args[option: "title"] != nil { throw CLIError.usage("--title goes with --start") }
            switch (args[option: "pane"], args[option: "session"]) {
            case (let pane?, nil): options.continueTarget = .pane(pane)
            case (nil, let session?): options.continueTarget = .session(session)
            case (nil, nil): options.continueTarget = .current
            default: throw CLIError.usage("give either --pane or --session")
            }
        } else {
            for option in ["account", "title", "prompt", "pane", "session"] where args[option: option] != nil {
                throw CLIError.usage("--\(option) goes with --start, --continue or --send")
            }
            if args.rest != nil { throw CLIError.usage("a command goes with --start") }
        }
        return options
    }

    /// `--at`, `--in`, `--every` (+ `--time`, `--tz`), `--after-limit` or `--after-codex-limit` (+ `--delay`,
    /// `--repeat`); nil when none is given.
    static func parseTrigger(_ args: Arguments, now: Date, timeZone: TimeZone) throws -> JSONValue? {
        var given = ["at", "in", "every", "after-limit"].filter { args[option: $0] != nil }
        let codex = args.has("after-codex-limit")
        if codex { given.append("after-codex-limit") }
        if given.count > 1 { throw CLIError.usage("give one trigger: " + given.map { "--\($0)" }.joined(separator: ", ")) }
        if args[option: "every"] == nil, args[option: "time"] != nil || args[option: "tz"] != nil {
            throw CLIError.usage("--time and --tz go with --every")
        }
        let limit = args[option: "after-limit"] != nil || codex
        if !limit, args[option: "delay"] != nil { throw CLIError.usage("--delay goes with --after-limit or --after-codex-limit") }
        if !limit, args.has("repeat") { throw CLIError.usage("--repeat goes with --after-limit or --after-codex-limit") }
        let delay = try args[option: "delay"].map { try parseDuration($0, option: "delay") } ?? ScheduleLimits.defaultDelay
        if codex {
            var trigger: [String: JSONValue] = ["type": "codexLimitReset", "delay": .number(delay)]
            if args.has("repeat") { trigger["repeats"] = .bool(true) }
            return .object(trigger)
        }
        if let at = args[option: "at"] {
            return ["type": "once", "at": .number(try parseAt(at, now: now, timeZone: timeZone).timeIntervalSince1970)]
        }
        if let delay = args[option: "in"] {
            let seconds = try parseDuration(delay, option: "in")
            return ["type": "once", "at": .number(now.addingTimeInterval(seconds).timeIntervalSince1970.rounded())]
        }
        if let every = args[option: "every"] {
            guard let rawTimes = args[option: "time"] else { throw CLIError.usage("--every needs --time HH:MM[,HH:MM]") }
            let times = try rawTimes.split(separator: ",").map { raw -> String in
                guard let time = TimeOfDay(String(raw)) else { throw CLIError.usage("--time expects HH:MM, got \(raw)") }
                return time.text
            }
            var trigger: [String: JSONValue] = [
                "type": "weekly",
                "weekdays": .array(try parseWeekdays(every).sorted().map { .string($0.rawValue) }),
                "times": .array(times.map { .string($0) }),
            ]
            if let zone = args[option: "tz"] {
                guard TimeZone(identifier: zone) != nil else { throw CLIError.usage("unknown time zone: \(zone)") }
                trigger["timeZone"] = .string(zone)
            }
            return .object(trigger)
        }
        if let account = args[option: "after-limit"] {
            var trigger: [String: JSONValue] = ["type": "limitReset", "account": .string(account), "delay": .number(delay)]
            if args.has("repeat") { trigger["repeats"] = .bool(true) }
            return .object(trigger)
        }
        return nil
    }

    /// `"2026-11-04 02:00"` (also with a `T`), or `"02:00"` = the next time it is 02:00.
    static func parseAt(_ raw: String, now: Date, timeZone: TimeZone) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if let time = TimeOfDay(raw) {
            guard let next = calendar.nextDate(after: now, matching: DateComponents(hour: time.hour, minute: time.minute, second: 0),
                                               matchingPolicy: .nextTime) else {
                throw CLIError.usage("--at: no such time \(raw)")
            }
            return next
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.isLenient = false
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd H:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw.trimmingCharacters(in: .whitespaces)) { return date }
        }
        throw CLIError.usage("--at expects \"YYYY-MM-DD HH:MM\" or HH:MM, got \(raw)")
    }

    /// `90m`, `2h`, `1h30m`, `45s`, `1d`.
    static func parseDuration(_ raw: String, option: String) throws -> TimeInterval {
        let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
        let invalid = CLIError.usage("--\(option) expects a duration like 90m, 2h, 1h30m or 45s, got \(raw)")
        var total: TimeInterval = 0
        var digits = ""
        for character in raw.lowercased() {
            if character.isASCII, character.isNumber {
                digits.append(character)
            } else if let unit = units[character], let value = Double(digits) {
                total += value * unit
                digits = ""
            } else {
                throw invalid
            }
        }
        guard digits.isEmpty, !raw.isEmpty else { throw invalid }
        return total
    }

    /// `weekdays`, `daily`, `weekends`, or days like `mon,wed,fri` (full names work too).
    static func parseWeekdays(_ raw: String) throws -> Set<Weekday> {
        switch raw.lowercased() {
        case "weekdays", "workdays": return Weekday.workdays
        case "daily", "everyday", "every-day": return Set(Weekday.allCases)
        case "weekends", "weekend": return [.sat, .sun]
        default: break
        }
        var days = Set<Weekday>()
        for part in raw.lowercased().split(separator: ",") {
            let word = part.trimmingCharacters(in: .whitespaces)
            guard word.count >= 3, let day = Weekday(rawValue: String(word.prefix(3))),
                  Self.dayNames[day]?.hasPrefix(word) == true else {
                throw CLIError.usage("--every expects weekdays, daily, weekends or days like mon,wed,fri; got \(raw)")
            }
            days.insert(day)
        }
        guard !days.isEmpty else { throw CLIError.usage("--every needs at least one day") }
        return days
    }

    private static let dayNames: [Weekday: String] = [
        .mon: "monday", .tue: "tuesday", .wed: "wednesday", .thu: "thursday", .fri: "friday", .sat: "saturday", .sun: "sunday",
    ]

    /// `skip` or a number of minutes.
    static func parseLate(_ raw: String) throws -> JSONValue {
        if raw.lowercased() == "skip" { return ["type": "skip"] }
        guard let minutes = Int(raw), minutes > 0 else { throw CLIError.usage("--late expects skip or a number of minutes") }
        return ["type": "runIfWithin", "seconds": .number(Double(minutes) * 60)]
    }

    /// `--send`: `target`, else this pane (`CMDS_PANE_ID`), which the app turns into a tag.
    static func sendAction(_ send: SendOptions, envPane: String?) throws -> JSONValue {
        let target: PaneTarget
        if let given = send.target {
            target = given
        } else if let envPane {
            target = .pane(envPane)
        } else {
            throw CLIError.usage("--send needs --pane P or --workspace TITLE outside a cmds terminal")
        }
        return try .from(ScheduleAction.sendText(SendText(target: target, text: send.text, to: send.to)))
    }

    /// `--continue`: the Claude Code or Codex session in `pane` (or the one with the given id) from `agent.sessions`.
    static func continueAction(target: ContinueTarget, pane: String?, sessions: AgentSessionList, account: String?,
                               prompt: String?) throws -> JSONValue {
        let entry: AgentSessionEntry?
        let sessionID: String
        switch target {
        case .session(let id):
            entry = sessions.sessions.first { $0.session.sessionID == id }
            sessionID = id
        case .pane, .current:
            let continuable: Set<AgentKind> = [.claude, .codex]
            guard let found = sessions.sessions.first(where: { $0.pane == pane && continuable.contains($0.session.agent) }) else {
                throw CLIError.failure("pane \(pane ?? "?") has no known Claude Code or Codex session "
                    + "(for Claude Code, add `cmds hook claude-status` to its status line)")
            }
            entry = found
            sessionID = found.session.sessionID
        }
        let agent = entry?.session.agent ?? .claude
        if let entry {
            guard agent == .claude || agent == .codex else {
                throw CLIError.failure("only Claude Code and Codex sessions can be continued")
            }
            guard entry.session.host == nil else {
                throw CLIError.failure("the session runs on \(entry.session.host ?? "a server"); only local sessions can be continued")
            }
        }
        if agent == .codex, account != nil { throw CLIError.usage("--account goes with Claude Code sessions only") }
        var action: [String: JSONValue] = ["type": "continueSession", "agent": .string(agent.rawValue), "sessionID": .string(sessionID)]
        if let cwd = entry?.session.cwd { action["cwd"] = .string(cwd) }
        if let account { action["account"] = .string(account) }
        if let prompt { action["prompt"] = .string(prompt) }
        // The chosen pane is the run's target when several panes hold the session.
        if let pane { action["pane"] = .string(pane) }
        return .object(action)
    }

    private static func absolute(_ path: String, base: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
        return ((base as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }
}

// MARK: - Output

extension Format {
    /// `cmds schedule`: one line per schedule.
    static func schedules(_ list: ScheduleList, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var out = list.readOnly ? "read only: the schedule files were written by a newer cmds or could not be read\n" : ""
        guard !list.schedules.isEmpty else { return out + "no schedules (add one: cmds schedule add --help)\n" }
        let nameWidth = min(list.schedules.map { oneLine($0.schedule.name).count }.max() ?? 0, 24)
        for entry in list.schedules {
            let schedule = entry.schedule
            var name = oneLine(schedule.name)
            if name.count > nameWidth { name = String(name.prefix(nameWidth - 1)) + "…" }
            var line = "\(schedule.id)  \(schedule.enabled ? "on " : "off")  "
                + name.padding(toLength: nameWidth, withPad: " ", startingAt: 0) + "  "
                + scheduleTrigger(schedule.trigger, timeZone: timeZone) + "  →  " + scheduleAction(schedule.action)
            if let run = entry.activeRun {
                line += "  [running: \(run.state.rawValue) \(run.id)]"
            } else if let next = entry.nextFireAt, schedule.enabled {
                line += "  next \(scheduleTime(next, timeZone: timeZone))"
            }
            if let last = entry.lastRun { line += "  last \(last.state.rawValue) \(AgentResume.relative(last.lastActivityAt, now: now))" }
            if let problem = entry.problem { line += "  ! \(problem)" }
            out += line + "\n"
        }
        return out
    }

    /// After add / edit / enable: the id and when it runs.
    static func scheduleAdded(_ entry: ScheduleListEntry, timeZone: TimeZone = .current) -> String {
        var line = entry.schedule.id
        if !entry.schedule.enabled {
            line += "  off"
        } else if let next = entry.nextFireAt {
            line += "  next run \(scheduleTime(next, timeZone: timeZone))"
        } else {
            line += "  no further run"
        }
        if let problem = entry.problem { line += "  ! \(problem)" }
        return line + "\n"
    }

    /// `cmds schedule show`.
    static func scheduleDetails(_ entry: ScheduleListEntry, runs: [ScheduleRun], now: Date = Date(),
                                timeZone: TimeZone = .current) -> String {
        let schedule = entry.schedule
        var out = "\(schedule.id)  \(oneLine(schedule.name))  (\(schedule.enabled ? "on" : "off"))\n"
        out += "when     \(scheduleTrigger(schedule.trigger, timeZone: timeZone))\n"
        out += "action   \(scheduleAction(schedule.action))\n"
        switch schedule.action {
        case .startWorkspace(let action):
            if let command = action.command { out += "command  \(command)\n" }
            if let prompt = action.prompt { out += "prompt   \(oneLine(prompt))\n" }
        case .continueSession(let action):
            out += "prompt   \(oneLine(action.prompt))\n"
        case .sendText(let action):
            out += "target   \(sendTarget(action.target))" + (entry.targetPane.map { " (now \($0))" } ?? "") + "\n"
            out += "text     \(oneLine(action.text))\n"
        }
        switch schedule.late {
        case .skip: out += "if late  skip\n"
        case .runIfWithin(let seconds): out += "if late  run when at most \(duration(seconds)) late\n"
        }
        out += "notify   \(schedule.notify.rawValue)\(schedule.warn ? ", 1 minute before" : "")\n"
        switch schedule.origin {
        case .app: out += "origin   app\n"
        case .api(let pane): out += "origin   api" + (pane.map { " (pane \($0))" } ?? "") + "\n"
        }
        out += "created  \(scheduleTime(schedule.createdAt, timeZone: timeZone))\n"
        if let next = entry.nextFireAt, schedule.enabled { out += "next     \(scheduleTime(next, timeZone: timeZone))\n" }
        if let problem = entry.problem { out += "problem  \(problem)\n" }
        if let run = entry.activeRun { out += "running  \(scheduleRun(run, timeZone: timeZone))\n" }
        for run in runs { out += "run      \(scheduleRun(run, timeZone: timeZone))\n" }
        return out
    }

    /// `cmds schedule history`.
    static func scheduleHistory(_ runs: [ScheduleRun], timeZone: TimeZone = .current) -> String {
        guard !runs.isEmpty else { return "no runs yet\n" }
        return runs.map { "\($0.scheduleID)  \(oneLine($0.scheduleName))  " + scheduleRun($0, timeZone: timeZone) + "\n" }.joined()
    }

    /// `r1a2b3c4d  2026-11-04 09:00  catch-up  succeeded — Claude Code started working on the prompt  w3 p7 (work)`.
    static func scheduleRun(_ run: ScheduleRun, timeZone: TimeZone = .current) -> String {
        var line = "\(run.id)  \(scheduleTime(run.startedAt, timeZone: timeZone))  "
        switch run.cause {
        case .scheduled: break
        case .catchUp: line += "catch-up  "
        case .manual: line += "manual  "
        }
        line += run.state.rawValue
        if let reason = run.reason { line += " — \(reason.english)" }
        let place = [run.workspace, run.pane].compactMap { $0 }.joined(separator: " ")
        if !place.isEmpty { line += "  \(place)" }
        if let account = run.account { line += " (\(account))" }
        return line
    }

    /// `weekdays 09:00, 13:30 (Asia/Tokyo)`, `once 2026-11-04 02:00`, `when work resets + 1m`.
    static func scheduleTrigger(_ trigger: ScheduleTrigger, timeZone: TimeZone = .current) -> String {
        switch trigger {
        case .once(let at):
            return "once \(scheduleTime(at, timeZone: timeZone))"
        case .weekly(let rule):
            let days: String
            if rule.weekdays == Set(Weekday.allCases) { days = "daily" }
            else if rule.weekdays == Weekday.workdays { days = "weekdays" }
            else if rule.weekdays == [.sat, .sun] { days = "weekends" }
            else { days = rule.weekdays.sorted().map(\.rawValue).joined(separator: ",") }
            return "\(days) \(rule.times.map(\.text).joined(separator: ", "))" + (rule.timeZone.map { " (\($0))" } ?? "")
        case .limitReset(let account, let delay, let repeats):
            return (repeats ? "every time \(account) resets" : "when \(account) resets") + (delay > 0 ? " + \(duration(delay))" : "")
        case .codexLimitReset(let delay, let repeats):
            return (repeats ? "every time Codex resets" : "when Codex resets") + (delay > 0 ? " + \(duration(delay))" : "")
        }
    }

    /// `pane t1a2b3c4d`, `workspace "API"`.
    static func sendTarget(_ target: PaneTarget) -> String {
        switch target {
        case .tag(let tag): return "pane \(tag)"
        case .pane(let pane): return "pane \(pane)"
        case .workspace(let title): return "workspace \"\(oneLine(title))\""
        }
    }

    /// `start ~/src/app (work): claude + prompt`, `continue session 6f1c2d3e (prompt "continue")`.
    static func scheduleAction(_ action: ScheduleAction) -> String {
        switch action {
        case .startWorkspace(let start):
            var text = "start \(abbreviate(start.cwd))"
            if let account = start.account { text += " (\(account))" }
            if let command = start.command { text += ": \(oneLine(command))" + (start.prompt != nil ? " + prompt" : "") }
            return text
        case .continueSession(let session):
            var text = "continue \(session.agent == .codex ? "Codex " : "")session \(session.sessionID.prefix(8))"
            if let account = session.account { text += " (\(account))" }
            return text + " with \"" + short(session.prompt) + "\""
        case .sendText(let send):
            return "send \"\(short(send.text))\" to the \(send.to.rawValue) in \(sendTarget(send.target))"
        }
    }

    /// One line of at most 24 characters.
    private static func short(_ text: String) -> String {
        let line = oneLine(text)
        return line.count > 24 ? String(line.prefix(23)) + "…" : line
    }

    /// `2026-11-04 02:00` in the Mac's zone.
    static func scheduleTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// `1m`, `90s`, `6h`, `1h30m`.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 || total % 60 != 0 { return "\(total)s" }
        let hours = total / 3600, minutes = total % 3600 / 60
        if hours == 0 { return "\(minutes)m" }
        return minutes == 0 ? "\(hours)h" : "\(hours)h\(minutes)m"
    }
}
