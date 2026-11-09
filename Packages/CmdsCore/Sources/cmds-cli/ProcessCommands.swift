import CmdsCore
import Foundation

// `cmds top` / `cmds kill`: the processes started from cmds terminals, and stopping leftovers (#193).
extension CLI {
    static let processCommands: [Command] = [
        Command(name: "top", usage: "top [--leftover] [--limit N] [--workspace W] [--pane P]",
                summary: "List the heaviest processes started from cmds terminals: memory, CPU, pane, workspace, command.",
                details: """
                    Every process started in a cmds terminal (shells, agents, dev servers, test runners, builds…), also after
                    its pane or workspace was closed: those are marked leftover (a dev server started with `&` or nohup, a
                    browser driver, a build daemon). Memory = physical footprint, CPU as in Activity Monitor (100% = one
                    core). Sampled every 2 s; no processes are started to read them. Heaviest first, --limit N of them
                    (default \(ProcessListRequest.defaultLimit), at most \(ProcessListRequest.maxLimit)). --leftover lists
                    only leftovers, --workspace / --pane only those of one workspace or pane. Stop one with `cmds kill PID`.
                    Processes not started from cmds terminals are not listed (use Activity Monitor). Not available on the
                    socket an SSH pane forwards to a server.
                    """,
                options: ["limit", "workspace", "pane"], flags: ["leftover"]) { ctx in
            try ctx.args.expectPositionals(0...0, usage: "cmds top [--leftover] [--limit N] [--workspace W] [--pane P]")
            var request = ProcessListRequest(workspace: ctx.args[option: "workspace"], pane: ctx.args[option: "pane"],
                                             leftover: ctx.args.has("leftover"))
            if let limit = try ctx.args.int("limit") {
                guard (1...ProcessListRequest.maxLimit).contains(limit) else {
                    throw CLIError.usage("--limit expects a number from 1 to \(ProcessListRequest.maxLimit)")
                }
                request.limit = limit
            }
            let result = try callNewMethod(ctx, "system.processes", request.params)
            if ctx.json { return ctx.printJSON(result) }
            let list = try perform { try result.decode(ProcessList.self) }
            let titles = workspaceTitles((try? ctx.call("workspace.list").decode([WorkspaceInfo].self)) ?? [])
            print(Format.processes(list, titles: titles, currentPane: ctx.envPane), terminator: "")
        },
        Command(name: "kill", usage: "kill <pid> [--force]",
                summary: "Stop a process started from a cmds terminal (SIGTERM; SIGKILL with --force).",
                details: """
                    Only processes `cmds top` lists (started from a cmds terminal, checked by pid and start time in the app);
                    any other pid is refused, as are pid 1 and cmds itself. Meant for leftovers: a dev server or test run
                    whose pane was closed. The sidebar's leftover row has Stop buttons for the same.
                    """,
                flags: ["force"], aliases: ["f": "force"]) { ctx in
            try ctx.args.expectPositionals(1...1, usage: "cmds kill <pid> [--force]")
            guard let pid = Int32(ctx.args.positionals[0]), pid > 0 else { throw CLIError.usage("pid must be a positive number") }
            let request = ProcessKillRequest(pid: pid, force: ctx.args.has("force"))
            let result = try callNewMethod(ctx, "system.kill_process", request.params)
            if ctx.json { return ctx.printJSON(result) }
            let outcome = try perform { try result.decode(ProcessKillResult.self) }
            print("sent \(outcome.signal) to \(outcome.pid) (\(outcome.name))")
        },
    ]
}
