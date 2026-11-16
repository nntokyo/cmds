import CmdsCore
import Foundation

// `cmds accounts …`: Claude Code accounts, their limits, and continuing a pane's session under another account
// (docs/guide/ai-agents.md "Several Claude accounts", docs/reference/cli.md).
extension CLI {
    static let accountCommands: [Command] = [
        Command(name: "accounts", usage: "accounts",
                summary: "List your Claude Code accounts: config directory, limit and reset time, shared sessions, panes.",
                details: """
                    An account is a name and a Claude Code config directory (CLAUDE_CONFIG_DIR) you signed in to yourself
                    (claude, then /login). cmds stores only names and paths. When a pane's account hits its limit, cmds
                    offers to continue the session with the next account in this order that has not (cmds accounts auto
                    on: by itself). Subcommands: add, remove, move, share, login, setup, chrome, clear, switch, auto. Use only your own
                    accounts; you are responsible for following Anthropic's terms for each. See docs/guide/ai-agents.md
                    "Several Claude accounts".
                    """) { ctx in
            try ctx.args.expectPositionals(0...0, usage: "cmds accounts")
            let result = try ctx.call("account.list")
            if ctx.json { return ctx.printJSON(result) }
            print(Format.accounts(try perform { try result.decode(ClaudeAccountList.self) }), terminator: "")
        },
        Command(name: "accounts add", usage: "accounts add <name> <config-dir>",
                summary: "Add a Claude account: a name and its config directory (absolute or ~/…; ~/.claude is plain claude's).",
                details: """
                    Names: letters, digits, - _ . @ (not "auto"). The directory may not exist yet:
                    `cmds accounts login NAME` signs it in. Only which Claude account it is signed in to is read from it.
                    """) { ctx in
            try ctx.args.expectPositionals(2...2, usage: "cmds accounts add <name> <config-dir>")
            var dir = ctx.args.positionals[1]
            // A relative path is taken from the current directory; ~/… stays as typed.
            if !dir.hasPrefix("/"), !dir.hasPrefix("~") { dir = absolutePath(dir) }
            let result = try ctx.call("account.add", ["name": .string(ctx.args.positionals[0]), "configDir": .string(dir)])
            if ctx.json { return ctx.printJSON(result) }
            print(Format.accounts(try perform { try result.decode(ClaudeAccountList.self) }), terminator: "")
        },
        Command(name: "accounts remove", usage: "accounts remove <name>",
                summary: "Remove a Claude account from cmds (its config directory is left as it is).") { ctx in
            try ctx.args.expectPositionals(1...1, usage: "cmds accounts remove <name>")
            try ctx.call("account.remove", ["name": .string(ctx.args.positionals[0])])
        },
        Command(name: "accounts move", usage: "accounts move <name> <position>",
                summary: "Move a Claude account to a position (1-based) in the switching order.") { ctx in
            try ctx.args.expectPositionals(2...2, usage: "cmds accounts move <name> <position>")
            guard let position = Int(ctx.args.positionals[1]), position >= 1 else { throw CLIError.usage("position must be 1 or more") }
            try ctx.call("account.move", ["name": .string(ctx.args.positionals[0]), "index": .number(Double(position - 1))])
        },
        Command(name: "accounts share", usage: "accounts share [--yes]",
                summary: "Share session transcripts between the accounts, so a session can continue under another account.",
                details: """
                    Claude Code keeps sessions in <config-dir>/projects. The first account (that exists) keeps its projects
                    folder; every other account's projects becomes a symbolic link to it. A projects folder of its own is
                    renamed to projects.before-cmds-<date> first (kept, never deleted), then the sessions in it the shared
                    folder lacks are copied there (nothing overwritten). Without --yes only shows what would be done.
                    """,
                flags: ["yes"]) { ctx in
            try ctx.args.expectPositionals(0...0, usage: "cmds accounts share [--yes]")
            let apply = ctx.args.has("yes")
            let result = try ctx.call("account.share", ["apply": .bool(apply)])
            if ctx.json { return ctx.printJSON(result) }
            guard case .array(let steps) = result else { return }
            print(Format.shareSteps(steps, applied: apply), terminator: "")
            if !apply { print("(nothing changed; run with --yes to do this)") }
        },
        Command(name: "accounts login", usage: "accounts login <name>",
                summary: "Open a workspace under a Claude account and run `claude auth login` there (sign in, or sign in as another account).",
                details: """
                    The same as Sign In in the sidebar's account menu and in Settings › Claude Accounts. The config
                    directory is created by Claude Code when it does not exist yet. Prints the workspace.
                    """) { ctx in
            try ctx.args.expectPositionals(1...1, usage: "cmds accounts login <name>")
            let result = try ctx.call("account.login", ["name": .string(ctx.args.positionals[0])])
            ctx.printResult(result, field: "workspace")
        },
        Command(name: "accounts setup", usage: "accounts setup <name>",
                summary: "Add cmds's status line and hooks to a Claude account's settings.json (what the account button and switching need).",
                details: """
                    Adds only what is missing to <config-dir>/settings.json: the status line (cmds hook claude-status;
                    the first account's status line when that one reports) when there is none, and the hooks
                    (cmds hook claude) for Notification, Stop, UserPromptSubmit, SubagentStart and SubagentStop.
                    Other settings stay; a status line of your own is left alone; the previous file is copied to
                    settings.json.cmds-backup-<time>. The same as Set Up for cmds in the sidebar's account menu. Sessions
                    started afterwards use it.
                    """) { ctx in
            try ctx.args.expectPositionals(1...1, usage: "cmds accounts setup <name>")
            let result = try ctx.call("account.setup", ["name": .string(ctx.args.positionals[0])])
            if ctx.json { return ctx.printJSON(result) }
            let added = (result["hooksAdded"]?.arrayValue ?? []).compactMap(\.stringValue)
            var parts: [String] = []
            if result["statusLineAdded"]?.boolValue == true { parts.append("status line added") }
            if !added.isEmpty { parts.append("hooks added: " + added.joined(separator: ", ")) }
            if result["statusLine"]?.stringValue == "own" {
                parts.append("the status line is your own: add `cmds hook claude-status` to it (docs/guide/ai-agents.md)")
            }
            print(parts.isEmpty ? "nothing to add" : parts.joined(separator: "; "))
            if let backup = result["backup"]?.stringValue { print("previous settings: \(backup)") }
        },
        Command(name: "accounts chrome", usage: "accounts chrome",
                summary: "Put back Claude in Chrome's host script when its config folder was made again (the extension cannot connect).",
                details: """
                    The browser's manifest (NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json) names
                    <config-dir>/chrome/chrome-native-host of the account that last turned Claude in Chrome on. When that
                    folder is removed or made again, the extension cannot connect under any account. This writes the
                    missing script (a copy of another account's, else `exec claude --chrome-native-host`); nothing is
                    overwritten and the manifest is not changed. `cmds accounts` says when it is missing.
                    """) { ctx in
            try ctx.args.expectPositionals(0...0, usage: "cmds accounts chrome")
            let result = try ctx.call("account.repair_chrome")
            if ctx.json { return ctx.printJSON(result) }
            let written = (result["written"]?.arrayValue ?? []).compactMap(\.stringValue)
            print(written.isEmpty ? "nothing to repair" : written.map { "wrote \($0)" }.joined(separator: "\n"))
        },
        Command(name: "accounts clear", usage: "accounts clear <name>",
                summary: "Forget a Claude account's recorded limit (e.g. it reset early or was detected wrongly).") { ctx in
            try ctx.args.expectPositionals(1...1, usage: "cmds accounts clear <name>")
            try ctx.call("account.clear_limit", ["name": .string(ctx.args.positionals[0])])
        },
        Command(name: "accounts switch", usage: "accounts switch [--pane P] [--to NAME]",
                summary: "Continue a pane's Claude Code session with another account (default: the next one without a limit).",
                details: """
                    Waits until Claude Code is idle at its prompt (never mid-turn), quits it with Ctrl-C and types
                    `env CLAUDE_CONFIG_DIR='<dir>' claude --resume <id>` into the pane's shell. Needs the session id
                    (`cmds hook claude-status` in the status line) and shared sessions (cmds accounts share).
                    Local panes only. Prints the account.
                    """,
                options: ["pane", "to"]) { ctx in
            try ctx.args.expectPositionals(0...0, usage: "cmds accounts switch [--pane P] [--to NAME]")
            let result = try ctx.call("account.switch", ["pane": ctx.pane.json, "account": ctx.args[option: "to"].json])
            ctx.printResult(result, field: "account")
        },
        Command(name: "accounts auto", usage: "accounts auto [on|off]",
                summary: "Show or set whether a pane switches to the next account by itself when its account hits its limit.") { ctx in
            try ctx.args.expectPositionals(0...1, usage: "cmds accounts auto [on|off]")
            var params: [String: JSONValue?] = [:]
            if let value = ctx.args.positionals.first {
                guard ["on", "off"].contains(value) else { throw CLIError.usage("expected on or off") }
                params["autoSwitch"] = .bool(value == "on")
            }
            let result = try ctx.call("account.set", params)
            if ctx.json { return ctx.printJSON(result) }
            let list = try perform { try result.decode(ClaudeAccountList.self) }
            print(list.autoSwitch ? "on" : "off")
        },
    ]
}
