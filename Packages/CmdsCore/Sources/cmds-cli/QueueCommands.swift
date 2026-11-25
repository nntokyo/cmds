import CmdsCore
import Foundation

// `cmds queue …` (instructions kept for a busy pane) and `cmds idle` (panes with nothing in progress).
extension CLI {
    private static let queueAddUsage = "queue add (--pane P | --workspace TITLE) <text…|->"

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
    ]
}
