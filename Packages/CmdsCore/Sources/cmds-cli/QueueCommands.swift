import CmdsCore
import Foundation

// `cmds queue …` (instructions kept for a busy pane) and `cmds idle` (panes with nothing in progress).
extension CLI {
    private static let queueAddUsage = "queue add (--pane P | --workspace TITLE) <text…|->"
    private static let powerNoticeUsage = "power notice [on|off] [--below N] [--request TEXT | --default-request]"
    private static let stallNoticeUsage = "stall notice [on|off] [--to PANE] [--input-minutes N] [--queue-minutes N]"

    static let queueCommands: [Command] = [
        Command(name: "queue add", usage: queueAddUsage,
                summary: "Keep an instruction for a pane whose agent is working; cmds types it in when the agent is free.",
                details: """
                    The text is pasted into Claude Code or Codex in that pane, then Return, once the agent is free: in the
                    foreground, not working, no subagent running, not asking for input or permission, no numbered choice
                    on screen, and its input box empty (text a person typed there is never joined or sent; the
                    instruction waits until the box is empty). It waits as long as that takes, also across a restart
                    of cmds, and is typed once. Several instructions for a pane go in one at a time, oldest first.
                    The pane is --pane P (an id from `cmds ls`) or --workspace TITLE, the only terminal pane of the
                    workspace with that title. Words are joined with spaces; `-` reads the text from stdin (line breaks
                    are kept). At most \(PaneQueue.maxPerPane) instructions wait per pane, each up to \
                    \(ScheduleLimits.maxPromptBytes / 1024) KiB. Prints the instruction's id and its place in the pane's
                    queue. See what waits and why with `cmds queue list`.
                    """,
                options: ["pane", "workspace"]) { ctx in
            guard !ctx.args.positionals.isEmpty else { throw CLIError.usage("usage: cmds \(queueAddUsage)") }
            let pane = ctx.args[option: "pane"], workspace = ctx.args[option: "workspace"]
            guard (pane == nil) != (workspace == nil) else {
                throw CLIError.usage("name the pane with --pane P or --workspace TITLE (one of them)")
            }
            let text = ctx.args.positionals == ["-"] ? readStandardInput() : ctx.args.positionals.joined(separator: " ")
            let result = try callNewMethod(ctx, "queue.add", [
                "pane": pane.map { .string($0) }, "workspace": workspace.map { .string($0) }, "text": .string(text),
                "from": ctx.envPane.map { .string($0) },
            ])
            if ctx.json { return ctx.printJSON(result) }
            print("\(result["id"]?.stringValue ?? "?") kept for pane \(result["pane"]?.stringValue ?? "?"), place \(result["position"]?.intValue ?? 1) in its queue")
        },
        Command(name: "queue list", usage: "queue list",
                summary: "List the instructions waiting for panes, why each pane's next one waits, and the last ones typed.",
                details: """
                    One line per waiting instruction: id, pane, workspace, place in the pane's queue, why the next one is
                    not typed yet (the agent is working, asks for input, its input box holds typed text, no agent runs in
                    the pane, the pane is not open…) and the start of its text. Then the last instructions that left the
                    queue: delivered (the agent was seen starting on it), unconfirmed (typed, not seen starting), failed
                    (the agent left before Return) or cancelled. --json for the full texts.
                    """) { ctx in
            try ctx.args.expectPositionals(0...0, usage: "cmds queue list")
            let result = try callNewMethod(ctx, "queue.list", [:])
            if ctx.json { return ctx.printJSON(result) }
            print(Format.queue(try perform { try result.decode(PaneQueueList.self) }), terminator: "")
        },
        Command(name: "queue cancel", usage: "queue cancel <id>",
                summary: "Take a waiting instruction out of a pane's queue (not one that is being typed).") { ctx in
            try ctx.args.expectPositionals(1...1, usage: "cmds queue cancel <id>")
            let result = try callNewMethod(ctx, "queue.cancel", ["id": .string(ctx.args.positionals[0])])
            if ctx.json { ctx.printJSON(result) }
        },
        Command(name: "idle", usage: "idle [--minutes N]",
                summary: "List the panes whose agent has had nothing in progress for N minutes (default \(IdlePanes.defaultMinutes)).",
                details: """
                    A pane is listed when its agent (Claude Code, Codex…) waits for a prompt or asks for input or
                    permission, no subagent runs and nothing is being typed into it by a schedule or a kept instruction,
                    and that has been so for --minutes N (default \(IdlePanes.defaultMinutes), 1 to \
                    \(IdlePanes.minutesRange.upperBound)). Longest first: pane, workspace, agent, how long, since when,
                    and how many kept instructions wait for it. `≥` before the time: cmds has not seen this agent work
                    since it started watching, so it may have been idle for longer. Panes without an agent are not
                    listed. Read only. --json for the API's answer.
                    """,
                options: ["minutes"]) { ctx in
            try ctx.args.expectPositionals(0...0, usage: "cmds idle [--minutes N]")
            let minutes = try ctx.args.int("minutes")
            if let minutes, !IdlePanes.minutesRange.contains(minutes) {
                throw CLIError.usage("--minutes expects a number from \(IdlePanes.minutesRange.lowerBound) to \(IdlePanes.minutesRange.upperBound)")
            }
            let result = try callNewMethod(ctx, "agent.idle", ["minutes": minutes.map { .number(Double($0)) }])
            if ctx.json { return ctx.printJSON(result) }
            print(Format.idlePanes(try perform { try result.decode(IdlePaneReport.self) }), terminator: "")
        },
        Command(name: "power", usage: "power",
                summary: "Show the Mac's power source and whether agents are told when it goes on battery.",
                details: """
                    Prints the power source (power adapter or battery, and the charge), whether the notice is on, the
                    line agents get, and the last one sent since cmds started. Read only; `cmds power notice` changes
                    it. --json for the API's answer.
                    """) { ctx in
            try ctx.args.expectPositionals(0...0, usage: "cmds power")
            let result = try callNewMethod(ctx, "power.status", [:])
            if ctx.json { return ctx.printJSON(result) }
            print(Format.power(try perform { try result.decode(PowerNoticeStatus.self) }), terminator: "")
        },
        Command(name: "power notice", usage: powerNoticeUsage,
                summary: "Tell every agent to wrap up when the Mac goes on battery or its battery runs low (off by default).",
                details: """
                    When on, cmds keeps one line for every pane that runs Claude Code or Codex (as `cmds queue add` does:
                    typed in when the agent is free, never into a question or over text a person typed) at two moments:
                    when the Mac switches from the power adapter to its battery, and when the charge falls below
                    --below N percent (default \(PowerNotice.defaultBelowPercent), \(PowerNotice.belowRange.lowerBound) to \
                    \(PowerNotice.belowRange.upperBound)) while it is not charging. The line, in Japanese, says which of the
                    two happened and the charge, then asks to wrap up, leave nothing half-applied and record the next step
                    in one line ("\(PowerNotice.defaultRequest)"). --request TEXT replaces that sentence (one line);
                    --default-request puts it back. Each moment is told once: again only after the Mac was back on the
                    adapter (or, for the level, \(PowerNotice.rearmMargin) points above it), and never twice to a pane that has not
                    read the last one. Turning it on while the battery is already below the level tells the agents now.
                    `cmds power` shows the state; `cmds queue list` the lines that wait.
                    """,
                options: ["below", "request"], flags: ["default-request"]) { ctx in
            let words = ctx.args.positionals
            guard words.count <= 1, words.allSatisfy({ $0 == "on" || $0 == "off" }) else {
                throw CLIError.usage("usage: cmds \(powerNoticeUsage)")
            }
            let below = try ctx.args.int("below")
            if let below, !PowerNotice.belowRange.contains(below) {
                throw CLIError.usage("--below expects a number from \(PowerNotice.belowRange.lowerBound) to \(PowerNotice.belowRange.upperBound)")
            }
            var request = ctx.args[option: "request"]
            if ctx.args.has("default-request") {
                guard request == nil else { throw CLIError.usage("give --request or --default-request, not both") }
                request = ""
            } else if let given = request, PowerNotice.oneLine(given) == nil {
                throw CLIError.usage("--request expects a line of text (--default-request for the usual one)")
            }
            guard !words.isEmpty || below != nil || request != nil else { throw CLIError.usage("usage: cmds \(powerNoticeUsage)") }
            let result = try callNewMethod(ctx, "power.set", [
                "enabled": words.first.map { .bool($0 == "on") }, "below": below.map { .number(Double($0)) },
                "request": request.map { .string($0) },
            ])
            if ctx.json { return ctx.printJSON(result) }
            print(Format.power(try perform { try result.decode(PowerNoticeStatus.self) }), terminator: "")
        },
        Command(name: "stall", usage: "stall",
                summary: "Show the panes that are stuck and whether a pane is told about them.",
                details: """
                    Prints whether the notice is on and which pane is told, then the panes that are stuck now: an agent
                    that has asked for input or permission for the set minutes, and a kept instruction (`cmds queue add`)
                    that has not been typed in for the set minutes, each with the minutes and the kind of reason. Read
                    only; `cmds stall notice` changes it. --json for the API's answer.
                    """) { ctx in
            try ctx.args.expectPositionals(0...0, usage: "cmds stall")
            let result = try callNewMethod(ctx, "stall.status", [:])
            if ctx.json { return ctx.printJSON(result) }
            print(Format.stall(try perform { try result.decode(StallNoticeStatus.self) }), terminator: "")
        },
        Command(name: "stall notice", usage: stallNoticeUsage,
                summary: "Tell one pane when another is stuck on a question or does not get its kept instruction (off by default).",
                details: """
                    When on, cmds looks at the panes once a minute and keeps one line for the pane given with --to (as
                    `cmds queue add` does: typed in when its agent is free) for each pane that is stuck: an agent that
                    has asked for input or permission for --input-minutes N (default \(StallNotice.defaultInputMinutes)), \
                    and a kept instruction that has not been typed in for --queue-minutes N (default \
                    \(StallNotice.defaultQueueMinutes)); both \(StallNotice.minutesRange.lowerBound) to \
                    \(StallNotice.minutesRange.upperBound). The line has a fixed form, in Japanese: the pane, the state, the
                    minutes and the kind of reason (permission-or-question, busy, needs-input, typed-input, no-agent,
                    other-program, other-input, pane-closed), and nothing from the pane's screen. cmds never answers the
                    question and never types into the stuck pane; no window comes forward. A stall that lasts is told
                    again every hour; the pane that is told is never reported itself. --to is needed the first time.
                    While on, the same lines are also written every minute to stalls.txt in the support folder
                    (`cmds stall` prints the path), for when the pane that is told is busy; off removes the file.
                    `cmds stall` shows the state; `cmds queue list` the lines that wait.
                    """,
                options: ["to", "input-minutes", "queue-minutes"]) { ctx in
            let words = ctx.args.positionals
            guard words.count <= 1, words.allSatisfy({ $0 == "on" || $0 == "off" }) else {
                throw CLIError.usage("usage: cmds \(stallNoticeUsage)")
            }
            let input = try ctx.args.int("input-minutes")
            let queue = try ctx.args.int("queue-minutes")
            for (minutes, name) in [(input, "--input-minutes"), (queue, "--queue-minutes")] {
                guard let minutes, !StallNotice.minutesRange.contains(minutes) else { continue }
                throw CLIError.usage("\(name) expects a number from \(StallNotice.minutesRange.lowerBound) to \(StallNotice.minutesRange.upperBound)")
            }
            let to = ctx.args[option: "to"]
            guard !words.isEmpty || to != nil || input != nil || queue != nil else {
                throw CLIError.usage("usage: cmds \(stallNoticeUsage)")
            }
            let result = try callNewMethod(ctx, "stall.set", [
                "enabled": words.first.map { .bool($0 == "on") }, "to": to.map { .string($0) },
                "input_minutes": input.map { .number(Double($0)) }, "queue_minutes": queue.map { .number(Double($0)) },
            ])
            if ctx.json { return ctx.printJSON(result) }
            print(Format.stall(try perform { try result.decode(StallNoticeStatus.self) }), terminator: "")
        },
    ]
}
