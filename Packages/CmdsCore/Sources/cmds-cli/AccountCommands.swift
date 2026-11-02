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
                    on: by itself). Subcommands: add, remove, move, share, clear, switch, auto. Use only your own
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
                    Names: letters, digits, - _ . @ (not "auto"). The directory may not exist yet: open a pane with
                    `cmds new --account NAME`, run claude and /login there. Nothing is read from the directory.
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
                    renamed to projects.before-cmds-<date> first (kept, never deleted or merged). Without --yes only
                    shows what would be done.
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
