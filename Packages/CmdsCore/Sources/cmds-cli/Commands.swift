import CmdsCore
import Foundation

extension CLI {
    static let commands: [Command] = [
        Command(name: "ping", usage: "ping", summary: "Check that the app is reachable.") { ctx in
            let result = try ctx.call("system.ping")
            ctx.json ? ctx.printJSON(result) : print("pong")
        },
        Command(name: "identify", usage: "identify", summary: "Show app version, pid and socket path.") { ctx in
            let result = try ctx.call("system.identify")
            if ctx.json { return ctx.printJSON(result) }
            print("cmds \(result["version"]?.stringValue ?? "?")  pid \(result["pid"]?.intValue ?? 0)  \(result["socketPath"]?.stringValue ?? "")")
        },
        Command(name: "ls", usage: "ls", summary: "List workspaces and their panes.",
                details: "Markers: * selected workspace, > focused pane, ! needs attention.") { ctx in
            let result = try ctx.call("workspace.list")
            if ctx.json { return ctx.printJSON(result) }
            let workspaces = try perform { try result.decode([WorkspaceInfo].self) }
            print(Format.workspaces(workspaces, currentPane: ctx.envPane), terminator: "")
        },
        Command(name: "new", usage: "new [--title T] [--cwd DIR] [-- command…]",
                summary: "Create a workspace (in the current directory by default) and select it.",
                options: ["title", "cwd"]) { ctx in
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
        Command(name: "split", usage: "split [right|down] [--pane P] [--browser URL] [--cwd DIR] [-- command…]",
                summary: "Split a pane (default: the current one, to the right) and focus the new pane.",
                details: "--browser opens a browser pane instead of a terminal. Prints the new pane id.",
                options: ["pane", "browser", "cwd"]) { ctx in
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
            ])
            if ctx.json { return ctx.printJSON(result) }
            print(result["id"]?.stringValue ?? "")
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
        Command(name: "browser open", usage: "browser open [--pane P] <url>",
                summary: "Open a browser split to the right of a pane (default: the current one).",
                options: ["pane"]) { ctx in
            try ctx.args.expectPositionals(1...1, usage: "cmds browser open [--pane P] <url>")
            let result = try ctx.call("browser.open", ["pane": ctx.pane.json, "url": .string(ctx.args.positionals[0])])
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
        Command(name: "hook claude", usage: "hook claude",
                summary: "Claude Code hook: read the hook JSON on stdin and notify (Notification / Stop events).",
                details: "Always exits 0 so a missing app never blocks Claude Code. See docs/CLI.md for the settings.json snippet.") { ctx in
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard let note = ClaudeHook.notification(fromHookInput: input) else { return }
            guard ctx.envPane != nil || ctx.args[option: "socket"] != nil || ctx.environment[CmdsEnv.socketPath] != nil else {
                return // not running inside cmds
            }
            do {
                try ctx.call("notify", ["pane": ctx.envPane.json, "title": note.title.json, "body": .string(note.body)], timeout: 5)
            } catch let error as CLIError {
                printError(error.message)
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

func absolutePath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
    let base = FileManager.default.currentDirectoryPath as NSString
    return (base.appendingPathComponent(expanded) as NSString).standardizingPath
}
