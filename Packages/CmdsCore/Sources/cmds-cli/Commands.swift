import CmdsCore
import Foundation

extension CLI {
    static let commands: [Command] = [
        Command(name: "ping", usage: "ping", summary: "Check that the app is reachable.") { ctx in
            let result = try ctx.call("system.ping")
            ctx.json ? ctx.printJSON(result) : print("pong")
        },
        Command(name: "quit", usage: "quit", summary: "Quit the app without the running-agents confirmation (for scripted updates).") { ctx in
            try ctx.call("app.quit")
        },
        Command(name: "identify", usage: "identify", summary: "Show app version, pid and socket path.") { ctx in
            let result = try ctx.call("system.identify")
            if ctx.json { return ctx.printJSON(result) }
            print("cmds \(result["version"]?.stringValue ?? "?")  pid \(result["pid"]?.intValue ?? 0)  \(result["socketPath"]?.stringValue ?? "")")
        },
        Command(name: "ls", usage: "ls", summary: "List workspaces and their panes.",
                details: "Markers: * selected workspace, > focused pane, ! needs attention. "
                    + "CPU/memory: see `cmds stats`.") { ctx in
            let result = try ctx.call("workspace.list")
            if ctx.json { return ctx.printJSON(result) }
            let workspaces = try perform { try result.decode([WorkspaceInfo].self) }
            print(Format.workspaces(workspaces, currentPane: ctx.envPane), terminator: "")
        },
        Command(name: "agents", usage: "agents [--subagents [--pane P]]",
                summary: "Show usage of the AI coding agents in cmds panes (Claude Code, Codex) and account limits.",
                details: """
                    One line per pane running an agent: context, cost ($/h), session and API time, lines changed, cache
                    (Claude Code, via `cmds hook claude-status` in its status line) or context and tokens (Codex, read
                    from its session file). Then the latest account limits per agent (5-hour / 7-day windows, spend limit).
                    --subagents lists Claude Code subagents instead (running and just finished; SubagentStart /
                    SubagentStop hooks): pane, state, elapsed time, type and description, current action, tokens.
                    """,
                options: ["pane"], flags: ["subagents"]) { ctx in
            try ctx.args.expectPositionals(0...0, usage: "cmds agents [--subagents [--pane P]]")
            if ctx.args.has("subagents") {
                let result = try ctx.call("agent.subagents", ["pane": ctx.args[option: "pane"].json])
                if ctx.json { return ctx.printJSON(result) }
                let list = try perform { try result.decode(SubagentList.self) }
                return print(Format.subagents(list, currentPane: ctx.envPane), terminator: "")
            }
            if ctx.args[option: "pane"] != nil { throw CLIError.usage("--pane goes with --subagents") }
            let result = try ctx.call("agent.list")
            if ctx.json { return ctx.printJSON(result) }
            let list = try perform { try result.decode(AgentList.self) }
            let workspaces = (try? ctx.call("workspace.list").decode([WorkspaceInfo].self)) ?? []
            let titles = Dictionary(workspaces.map { ($0.id, $0.title) }) { first, _ in first }
            print(Format.agents(list, titles: titles, currentPane: ctx.envPane), terminator: "")
        },
        Command(name: "sessions", usage: "sessions [--pane P]",
                summary: "List the AI agent sessions remembered per pane (resumable after cmds restarts).",
                details: """
                    One line per terminal pane: state (offered = from before the restart, waiting = resume queued until
                    the shell prompt is ready, running, resumed), agent, session id, directory (and SSH host) and the
                    command `cmds resume` types into the pane. See docs/guide/ai-agents.md "Resuming sessions".
                    """,
                options: ["pane"]) { ctx in
            try ctx.args.expectPositionals(0...0, usage: "cmds sessions [--pane P]")
            let result = try ctx.call("agent.sessions", ["pane": ctx.args[option: "pane"].json])
            if ctx.json { return ctx.printJSON(result) }
            let list = try perform { try result.decode(AgentSessionList.self) }
            print(Format.agentSessions(list, currentPane: ctx.envPane), terminator: "")
        },
        Command(name: "resume", usage: "resume [--pane P | --all]",
                summary: "Resume the agent session offered in a pane after a restart (default: the current pane).",
                details: """
                    Types `claude --resume <id>` or `codex resume <id>` (after `cd` to its directory) into the pane's own
                    shell as soon as its prompt is ready — so running it in the pane itself works. --all resumes every
                    offered session. Panes without an offered session, or already running an agent, are skipped.
                    """,
                options: ["pane"], flags: ["all"]) { ctx in
            try ctx.args.expectPositionals(0...0, usage: "cmds resume [--pane P | --all]")
            let all = ctx.args.has("all")
            if all, ctx.args[option: "pane"] != nil { throw CLIError.usage("give either --pane or --all") }
            let result = try ctx.call("agent.resume", all ? ["all": .bool(true)] : ["pane": ctx.pane.json])
            if ctx.json { return ctx.printJSON(result) }
            let outcome = try perform { try result.decode(AgentResumeResult.self) }
            for pane in outcome.queued { print("\(pane): resuming") }
            for skipped in outcome.skipped { print("\(skipped.pane): skipped — \(skipped.reason)") }
            if outcome.queued.isEmpty, outcome.skipped.isEmpty { print("no offered sessions") }
            if outcome.queued.isEmpty, !outcome.skipped.isEmpty { throw CLIError.failure("nothing to resume") }
        },
        exportCommand,  // TransferCommands.swift
        importCommand,
        Command(name: "stats", usage: "stats [--watch [seconds]]",
                summary: "Show CPU and memory use of the Mac and of each workspace's processes.",
                details: """
                    Workspace figures cover every process started in its terminals (shells, agents, dev servers…):
                    CPU as in Activity Monitor (100% = one core, so it can exceed 100%), memory = physical footprint.
                    The system line is the share of all cores, memory used / installed and the memory pressure
                    (normal, warning, critical). Values are sampled every 2 s.
                    The awake line shows whether cmds blocks idle sleep and whether closing the lid sleeps the Mac
                    (cmds › Keep Awake With Lid Closed; JSON: keepAwake {idleAssertion, lidCloseDisabled, …}).
                    --watch (-w) refreshes every 2 s, or the given seconds, until interrupted; with --json it prints
                    one JSON object per line.
                    """,
                flags: ["watch"], aliases: ["w": "watch"]) { ctx in
            let usage = "cmds stats [--watch [seconds]]"
            try ctx.args.expectPositionals(0...(ctx.args.has("watch") ? 1 : 0), usage: usage)
            var interval: TimeInterval?
            if ctx.args.has("watch") {
                interval = 2
                if let raw = ctx.args.positionals.first {
                    guard let seconds = TimeInterval(raw), seconds >= 0.5, seconds <= 3600 else {
                        throw CLIError.usage("--watch expects seconds between 0.5 and 3600")
                    }
                    interval = seconds
                }
            }
            let client = try ctx.connect()
            defer { client.close() }
            let terminal = isatty(STDOUT_FILENO) != 0
            while true {
                let result = try perform { try client.call("system.stats") }
                if ctx.json {
                    ctx.printJSON(result, compact: interval != nil)
                } else {
                    let snapshot = try perform { try result.decode(StatsSnapshot.self) }
                    let list = try perform { try client.call("workspace.list").decode([WorkspaceInfo].self) }
                    let titles = Dictionary(list.map { ($0.id, $0.title) }) { first, _ in first }
                    let text = Format.stats(snapshot, titles: titles, currentWorkspace: ctx.envWorkspace)
                    if interval != nil, terminal { print("\u{1B}[H\u{1B}[2J", terminator: "") } // clear screen
                    print(text, terminator: "")
                    if interval != nil, !terminal { print("") }
                }
                guard let interval else { return }
                Thread.sleep(forTimeInterval: interval)
            }
        },
        Command(name: "sync", usage: "sync",
                summary: "Show the iOS sync status: listener, Bonjour, Bluetooth, SSH remote access and connected devices.",
                details: """
                    Read-only. Bluetooth shows the app's permission (CBManager authorization: allowedAlways, denied,
                    restricted, notDetermined), the peripheral state, advertising and the L2CAP PSM. Each connection shows
                    its device name, whether it authenticated, its peer (IP, bluetooth:<peer> or ssh:<relay host>), path,
                    subscribed panes, bytes sent/received and how long it has been connected. Not available on the
                    socket an SSH pane forwards to a server. See docs/internals/testing.md "Testing sync on a device".
                    """) { ctx in
            try ctx.args.expectPositionals(0...0, usage: "cmds sync")
            let result = try ctx.call("sync.status")
            if ctx.json { return ctx.printJSON(result) }
            print(Format.sync(try perform { try result.decode(SyncStatusReport.self) }), terminator: "")
        },
        Command(name: "new", usage:"new [--title T] [--cwd DIR] [-- command…] | new --ssh HOST [--remote-cwd DIR] [--title T]",
                summary: "Create a workspace (in the current directory by default) and select it.",
                details: """
                    --ssh opens an SSH workspace: the pane runs your `ssh HOST` (respecting ~/.ssh/config) and forwards a
                    restricted cmds socket to the server for cmds-remote.sh (docs/internals/ssh.md). --remote-cwd is a directory on
                    the server (absolute or ~/…).
                    """,
                options: ["title", "cwd", "ssh", "remote-cwd"]) { ctx in
            if let host = ctx.args[option: "ssh"] {
                guard ctx.args[option: "cwd"] == nil, ctx.args.rest == nil else {
                    throw CLIError.usage("--ssh takes --remote-cwd, not --cwd or a command")
                }
                let result = try ctx.call("workspace.create", [
                    "ssh": .string(host),
                    "remoteCwd": ctx.args[option: "remote-cwd"].json,
                    "title": ctx.args[option: "title"].json,
                ])
                if ctx.json { return ctx.printJSON(result) }
                return print(result["id"]?.stringValue ?? "")
            }
            let cwd = ctx.args[option: "cwd"] ?? FileManager.default.currentDirectoryPath
            let result = try ctx.call("workspace.create", [
                "title": ctx.args[option: "title"].json,
                "cwd": .string(absolutePath(cwd)),
                "command": shellCommand(ctx.args.rest ?? []).json,
            ])
            if ctx.json { return ctx.printJSON(result) }
            print(result["id"]?.stringValue ?? "")
        },
        Command(name: "select", usage: "select <workspace-id|index|title>",
                summary: "Select a workspace (index is 1-based, as in ⌘1…⌘9).") { ctx in
            try ctx.args.expectPositionals(1...1, usage: "cmds select <workspace-id|index|title>")
            let id = try resolveWorkspace(ctx, ctx.args.positionals[0])
            try ctx.call("workspace.select", ["id": .string(id)])
        },
        Command(name: "tile", usage: "tile [--all | --off | <workspace>…]",
                summary: "Show several workspaces side by side (tiled view), or one again.",
                details: """
                    Workspaces are ids, 1-based indexes or titles (as for `cmds select`); give at least two. --all tiles
                    every workspace the sidebar shows (its filter applies, up to 9). --off shows only the active
                    workspace again. Without arguments prints what is tiled, in display order (rows the user
                    arranged by dragging are separated by " / "). Workspaces given here get the automatic layout.
                    Same as ⌘-click in the sidebar and View › Tile All Workspaces (⌃⌘T).
                    """,
                flags: ["all", "off"]) { ctx in
            let all = ctx.args.has("all")
            let off = ctx.args.has("off")
            let positionals = ctx.args.positionals
            if [all, off, !positionals.isEmpty].filter({ $0 }).count > 1 {
                throw CLIError.usage("give either --all, --off or workspaces")
            }
            var params: [String: JSONValue?] = [:]
            if all { params["all"] = .bool(true) }
            if off { params["off"] = .bool(true) }
            if !positionals.isEmpty {
                guard positionals.count >= 2 else { throw CLIError.usage("tiling needs at least two workspaces") }
                params["workspaces"] = .array(try positionals.map { .string(try resolveWorkspace(ctx, $0)) })
            }
            let result = try ctx.call("view.tile", params)
            if ctx.json { return ctx.printJSON(result) }
            let status = try perform { try result.decode(TileStatus.self) }
            guard status.mode != .off else { return print("not tiled") }
            func names(_ ids: [String]) -> String { ids.map { $0 == status.active ? "*\($0)" : $0 }.joined(separator: " ") }
            // A user-made arrangement prints its rows, top to bottom, separated by " / ".
            var line = "tiled (\(status.mode.rawValue)): "
                + (status.rows.map { $0.map(names).joined(separator: " / ") } ?? names(status.workspaces))
            if let zoomed = status.zoomed { line += "  zoomed \(zoomed)" }
            if status.hidden > 0 { line += "  (\(status.hidden) more not shown)" }
            print(line)
        },
        Command(name: "close", usage: "close [workspace]", summary: "Close a workspace (default: the current one).") { ctx in
            try ctx.args.expectPositionals(0...1, usage: "cmds close [workspace]")
            let id = try ctx.args.positionals.first.map { try resolveWorkspace(ctx, $0) } ?? ctx.envWorkspace
            try ctx.call("workspace.close", ["id": id.json])
        },
        Command(name: "rename", usage: "rename [workspace] <title>",
                summary: "Rename a workspace (default: the current one). An empty title restores the automatic name.") { ctx in
            try ctx.args.expectPositionals(1...2, usage: "cmds rename [workspace] <title>")
            let positionals = ctx.args.positionals
            let id = positionals.count == 2 ? try resolveWorkspace(ctx, positionals[0]) : ctx.envWorkspace
            try ctx.call("workspace.rename", ["id": id.json, "title": .string(positionals.last!)])
        },
        Command(name: "split", usage: "split [right|down] [--pane P] [--browser URL | --ssh HOST [--remote-cwd DIR]] [--cwd DIR] [--no-focus] [-- command…]",
                summary: "Split a pane (default: the current one, to the right) and focus the new pane.",
                details: """
                    --browser opens a browser pane instead of a terminal; --ssh an SSH pane (docs/internals/ssh.md). Splitting an SSH
                    pane without --cwd or a command opens another connection to the same host. --no-focus keeps the
                    keyboard in the current pane. Prints the new pane id.
                    """,
                options: ["pane", "browser", "cwd", "ssh", "remote-cwd"], flags: ["no-focus"]) { ctx in
            try ctx.args.expectPositionals(0...1, usage: "cmds split [right|down] [options]")
            let direction = ctx.args.positionals.first ?? "right"
            guard ["right", "down"].contains(direction) else { throw CLIError.usage("direction must be right or down") }
            let url = ctx.args[option: "browser"]
            let result = try ctx.call("pane.split", [
                "pane": ctx.pane.json,
                "direction": .string(direction),
                "kind": url == nil ? nil : "browser",
                "url": url.json,
                "cwd": ctx.args[option: "cwd"].map { .string(absolutePath($0)) },
                "command": shellCommand(ctx.args.rest ?? []).json,
                "focus": ctx.args.has("no-focus") ? false : nil,
                "ssh": ctx.args[option: "ssh"].json,
                "remoteCwd": ctx.args[option: "remote-cwd"].json,
            ])
            if ctx.json { return ctx.printJSON(result) }
            print(result["id"]?.stringValue ?? "")
        },
        Command(name: "reconnect", usage: "reconnect [pane]",
                summary: "Reconnect an SSH pane whose ssh exited (as ⌘R or its Reconnect button do).") { ctx in
            try ctx.args.expectPositionals(0...1, usage: "cmds reconnect [pane]")
            try ctx.call("pane.reconnect", ["pane": (ctx.args.positionals.first ?? ctx.envPane).json])
        },
        Command(name: "remote-helper", usage: "remote-helper",
                summary: "Print cmds-remote.sh, the sh client for servers reached through an SSH pane (docs/internals/ssh.md).",
                details: "E.g. `cmds remote-helper > cmds-remote.sh` to copy it yourself. In the app: Pane → Install Remote Helper….") { _ in
            print(RemoteHelperScript.source, terminator: "")
        },
        Command(name: "panes", usage: "panes [--workspace W]", summary: "List the panes of a workspace.",
                options: ["workspace"]) { ctx in
            let result = try ctx.call("pane.list", ["workspace": ctx.workspace.json])
            if ctx.json { return ctx.printJSON(result) }
            let panes = try perform { try result.decode([PaneInfo].self) }
            for pane in panes { print(Format.pane(pane, currentPane: ctx.envPane)) }
        },
        Command(name: "focus", usage: "focus <pane>", summary: "Focus a pane (selects its workspace).") { ctx in
            try ctx.args.expectPositionals(1...1, usage: "cmds focus <pane>")
            try ctx.call("pane.focus", ["pane": .string(ctx.args.positionals[0])])
        },
        Command(name: "close-pane", usage: "close-pane [pane]", summary: "Close a pane (default: the current one).") { ctx in
            try ctx.args.expectPositionals(0...1, usage: "cmds close-pane [pane]")
            try ctx.call("pane.close", ["pane": (ctx.args.positionals.first ?? ctx.envPane).json])
        },
        Command(name: "send", usage: "send [--pane P] [--enter] <text…|->",
                summary: "Type text into a terminal pane.",
                details: "Words are joined with spaces; `-` reads the text from stdin. --enter (-e) appends a newline (Return).",
                options: ["pane"], flags: ["enter"], aliases: ["e": "enter"]) { ctx in
            guard !ctx.args.positionals.isEmpty else { throw CLIError.usage("usage: cmds send [--pane P] [--enter] <text…|->") }
            var text = ctx.args.positionals == ["-"] ? readStandardInput() : ctx.args.positionals.joined(separator: " ")
            if ctx.args.has("enter") { text += "\n" }
            try ctx.call("pane.send_text", ["pane": ctx.pane.json, "text": .string(text)])
        },
        Command(name: "read", usage: "read [--pane P] [--scrollback N]",
                summary: "Print a terminal pane's visible text, or the last N lines including scrollback.",
                options: ["pane", "scrollback"], aliases: ["n": "scrollback"]) { ctx in
            let result = try ctx.call("pane.read_text", [
                "pane": ctx.pane.json,
                "scrollback": try ctx.args.int("scrollback").map { .number(Double($0)) },
            ])
            if ctx.json { return ctx.printJSON(result) }
            let text = result["text"]?.stringValue ?? ""
            print(text, terminator: text.hasSuffix("\n") ? "" : "\n")
        },
        Command(name: "notify", usage: "notify [--title T] [--pane P] <body…>",
                summary: "Light the pane's attention ring and show the text in the sidebar.",
                details: "Also posts a macOS notification while cmds is in the background.",
                options: ["title", "pane"], aliases: ["t": "title"]) { ctx in
            guard !ctx.args.positionals.isEmpty else { throw CLIError.usage("usage: cmds notify [--title T] <body…>") }
            let body = ctx.args.positionals == ["-"] ? readStandardInput() : ctx.args.positionals.joined(separator: " ")
            try ctx.call("notify", ["pane": ctx.pane.json, "title": ctx.args[option: "title"].json,
                                    "body": .string(body.trimmingCharacters(in: .whitespacesAndNewlines))])
        },
        Command(name: "status", usage: "status [--workspace W] <text…>",
                summary: "Set the workspace's sidebar text without ringing (empty text clears it).",
                options: ["workspace"]) { ctx in
            guard !ctx.args.positionals.isEmpty else { throw CLIError.usage("usage: cmds status [--workspace W] <text…>") }
            try ctx.call("sidebar.set_status", ["workspace": ctx.workspace.json,
                                                "text": .string(ctx.args.positionals.joined(separator: " "))])
        },
        Command(name: "open", usage: "open [--pane P] [--down] [--no-focus] [--diff] <file|->",
                summary: "Show a file in a preview pane split to the right of a pane (default: the current one).",
                details: """
                    Images, PDF, video, Office documents and text/code use Quick Look; Markdown (.md) is rendered; unified
                    diffs (.diff/.patch, or any file with --diff) are coloured. The pane reloads when the file changes.
                    Relative paths are resolved against the current directory. `-` reads stdin into a temporary file
                    (e.g. `git diff | cmds open --diff -`). --pane naming a preview pane shows the file in that pane
                    instead of splitting. --down splits below, --no-focus keeps the keyboard in the current pane.
                    Not available from SSH panes (the file is on the server). Prints the preview pane id.
                    """,
                options: ["pane"], flags: ["down", "no-focus", "diff"]) { ctx in
            try ctx.args.expectPositionals(1...1, usage: "cmds open [--pane P] [--down] [--no-focus] [--diff] <file|->")
            let argument = ctx.args.positionals[0]
            let path: String
            if argument == "-" {
                path = try writeStandardInputToTemporaryFile(extension: ctx.args.has("diff") ? "diff" : "txt")
            } else {
                path = absolutePath(argument)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                    throw CLIError.failure("no such file: \(argument)")
                }
                guard !isDirectory.boolValue else { throw CLIError.failure("\(argument) is a directory") }
            }
            let result = try ctx.call("pane.open_file", [
                "pane": ctx.pane.json,
                "path": .string(path),
                "direction": ctx.args.has("down") ? "down" : nil,
                "focus": ctx.args.has("no-focus") ? false : nil,
                "format": ctx.args.has("diff") ? "diff" : nil,
            ])
            if ctx.json { return ctx.printJSON(result) }
            print(result["id"]?.stringValue ?? "")
        },
        Command(name: "browser open", usage: "browser open [--pane P] [--no-focus] <url>",
                summary: "Open a browser split to the right of a pane (default: the current one).",
                details: "--no-focus keeps the keyboard in the current pane. Prints the new pane id.",
                options: ["pane"], flags: ["no-focus"]) { ctx in
            try ctx.args.expectPositionals(1...1, usage: "cmds browser open [--pane P] [--no-focus] <url>")
            let result = try ctx.call("browser.open", ["pane": ctx.pane.json, "url": .string(ctx.args.positionals[0]),
                                                       "focus": ctx.args.has("no-focus") ? false : nil])
            if ctx.json { return ctx.printJSON(result) }
            print(result["id"]?.stringValue ?? "")
        },
        Command(name: "browser navigate", usage: "browser navigate [--pane P] <url>",
                summary: "Load a URL in a browser pane.", details: browserPaneNote, options: ["pane"]) { ctx in
            try ctx.args.expectPositionals(1...1, usage: "cmds browser navigate [--pane P] <url>")
            try ctx.call("browser.navigate", browserTarget(ctx).merging(["url": .string(ctx.args.positionals[0])]) { $1 })
        },
        Command(name: "browser url", usage: "browser url [--pane P]",
                summary: "Print the URL and title of a browser pane.", details: browserPaneNote, options: ["pane"]) { ctx in
            let result = try ctx.call("browser.get_url", browserTarget(ctx))
            if ctx.json { return ctx.printJSON(result) }
            print(result["url"]?.stringValue ?? "")
            if let title = nonEmpty(result["title"]?.stringValue) { print(title) }
        },
        Command(name: "browser eval", usage: "browser eval [--pane P] <script|->",
                summary: "Evaluate JavaScript in a browser pane and print the JSON result.",
                details: "The script may use `await`; its value must be JSON-serializable.\n" + browserPaneNote,
                options: ["pane"]) { ctx in
            try ctx.args.expectPositionals(1...1, usage: "cmds browser eval [--pane P] <script|->")
            let script = ctx.args.positionals[0] == "-" ? readStandardInput() : ctx.args.positionals[0]
            let result = try ctx.call("browser.eval", browserTarget(ctx).merging(["script": .string(script)]) { $1 },
                                      timeout: 120)
            if ctx.json { return ctx.printJSON(result) }
            let value = result["value"] ?? .null
            if case .string(let string) = value { print(string) } else { ctx.printJSON(value) }
        },
        Command(name: "browser snapshot", usage: "browser snapshot [--pane P] [-o file.png]",
                summary: "Save a PNG of a browser pane's visible page.",
                details: "Without -o the PNG is written to stdout when it is not a terminal.\n" + browserPaneNote,
                options: ["pane", "output"], aliases: ["o": "output"]) { ctx in
            let result = try ctx.call("browser.snapshot", browserTarget(ctx), timeout: 120)
            if ctx.json { return ctx.printJSON(result) }
            guard let base64 = result["png_base64"]?.stringValue, let png = Data(base64Encoded: base64) else {
                throw CLIError.failure("snapshot returned no image")
            }
            if let output = ctx.args[option: "output"] {
                do { try png.write(to: URL(fileURLWithPath: absolutePath(output))) } catch {
                    throw CLIError.failure("cannot write \(output): \(error.localizedDescription)")
                }
                print(absolutePath(output))
            } else if isatty(STDOUT_FILENO) == 0 {
                FileHandle.standardOutput.write(png)
            } else {
                throw CLIError.usage("refusing to write PNG to a terminal; use -o file.png")
            }
        },
        Command(name: "events", usage: "events",
                summary: "Stream state changes as JSON lines until interrupted.",
                details: "Events: notification, workspace.changed, pane.changed, workspaces.changed.") { ctx in
            let client = try ctx.connect(timeout: 30)
            _ = try perform { try client.call("events.subscribe") }
            client.setTimeout(nil)
            while let event = try perform({ try client.nextEvent() }) {
                print(encodeJSON(try JSONValue.from(event), pretty: false))
            }
        },
        Command(name: "rpc", usage: "rpc <method> [json-params|-]",
                summary: "Call any API method with raw JSON params and print the JSON result.",
                details: "Example: cmds rpc pane.split '{\"direction\":\"down\"}'. Parameters are sent as given (no CMDS_* defaults).") { ctx in
            try ctx.args.expectPositionals(1...2, usage: "cmds rpc <method> [json-params|-]")
            var params: JSONValue?
            if ctx.args.positionals.count == 2 {
                let raw = ctx.args.positionals[1] == "-" ? readStandardInput() : ctx.args.positionals[1]
                guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)) else {
                    throw CLIError.usage("params are not valid JSON")
                }
                params = value
            }
            let client = try ctx.connect(timeout: 120)
            ctx.printJSON(try perform { try client.call(ctx.args.positionals[0], params: params) })
        },
        Command(name: "hook claude-status", usage: "hook claude-status",
                summary: "Claude Code status line: read its JSON on stdin and report the session usage for this pane.",
                details: "Prints nothing and always exits 0 within ~200 ms; a no-op outside cmds. See docs/guide/ai-agents.md for the status-line snippet.") { ctx in
            AgentHook.claudeStatus(ctx)
        },
        Command(name: "hook claude", usage: "hook claude",
                summary: "Claude Code hook: read the hook JSON on stdin; notify (Notification / Stop), track the agent's state (UserPromptSubmit) and its subagents (SubagentStart / SubagentStop).",
                details: "Always exits 0 so a missing app never blocks Claude Code. See docs/guide/ai-agents.md for the settings.json snippet.") { ctx in
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard let event = ClaudeHook.event(fromHookInput: input) else { return }
            guard ctx.envPane != nil || ctx.args[option: "socket"] != nil || ctx.environment[CmdsEnv.socketPath] != nil else {
                return // not running inside cmds
            }
            let forwarded = ClaudeHook.forwardedInput(fromHookInput: input, event: event)
            do {
                try ctx.call("agent.claude_hook", ["pane": ctx.envPane.json, "input": forwarded], timeout: 5)
            } catch {
                // An older app without `agent.claude_hook`: plain notification.
                guard let note = event.notification else { return }
                do {
                    try ctx.call("notify", ["pane": ctx.envPane.json, "title": note.title.json, "body": .string(note.body)], timeout: 5)
                } catch let error as CLIError {
                    printError(error.message)
                }
            }
        },
    ]

    static let browserPaneNote = "Without --pane, uses the focused browser pane of the current workspace (or its first browser pane)."

    /// `--pane` if given, else a workspace hint so the app can pick a browser pane in our workspace.
    static func browserTarget(_ ctx: Context) -> [String: JSONValue?] {
        if let pane = ctx.args[option: "pane"] { return ["pane": .string(pane)] }
        return ["workspace": ctx.envWorkspace.json]
    }

    /// Accepts a workspace id (`w3`), a 1-based index or an exact title.
    static func resolveWorkspace(_ ctx: Context, _ selector: String) throws -> String {
        let list = try perform { try ctx.call("workspace.list").decode([WorkspaceInfo].self) }
        if let match = list.first(where: { $0.id == selector }) { return match.id }
        if let index = Int(selector) {
            guard list.indices.contains(index - 1) else { throw CLIError.failure("no workspace at index \(index)") }
            return list[index - 1].id
        }
        let titled = list.filter { $0.title == selector }
        guard titled.count == 1 else {
            throw CLIError.failure(titled.isEmpty ? "workspace not found: \(selector)" : "several workspaces are titled \(selector)")
        }
        return titled[0].id
    }
}

/// Saves stdin under `$TMPDIR/cmds-preview/` (owner-only) for `cmds open -`.
func writeStandardInputToTemporaryFile(extension ext: String) throws -> String {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-preview", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    } catch {
        throw CLIError.failure("cannot create \(directory.path): \(error.localizedDescription)")
    }
    let file = directory.appendingPathComponent("stdin-\(UUID().uuidString.prefix(8)).\(ext)")
    guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
        throw CLIError.failure("cannot write \(file.path)")
    }
    return file.path
}

func absolutePath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
    let base = FileManager.default.currentDirectoryPath as NSString
    return (base.appendingPathComponent(expanded) as NSString).standardizingPath
}
