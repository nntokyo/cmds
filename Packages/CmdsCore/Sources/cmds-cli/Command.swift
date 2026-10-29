import Foundation

/// One CLI subcommand. Grouped commands use a space in `name` (`browser eval`, `hook claude`).
struct Command {
    let name: String
    let usage: String
    let summary: String
    var details: String = ""
    var options: Set<String> = []
    var flags: Set<String> = []
    var aliases: [Character: String] = [:]
    let run: (Context) throws -> Void

    var help: String {
        var text = "usage: cmds \(usage)\n\n\(summary)\n"
        if !details.isEmpty { text += "\n\(details)\n" }
        text += "\nGlobal options:\n  --json           print the raw JSON result\n  --socket PATH    socket to use (default: $CMDS_SUPPORT_DIR/cmds.sock, else $CMDS_SOCKET_PATH,\n                   else ~/Library/Application Support/cmds/cmds.sock)\n"
        return text
    }
}

enum CLI {
    static let version = "0.1.0"

    static func main(_ argv: [String], environment: [String: String]) -> Int32 {
        var words = argv
        if words.isEmpty || ["-h", "--help", "help"].contains(words[0]) {
            if words.count >= 2, words[0] == "help", let (command, _) = lookup(Array(words.dropFirst())) {
                print(command.help, terminator: "")
            } else {
                print(overview, terminator: "")
            }
            return 0
        }
        if words[0] == "--version" || words[0] == "version" {
            print("cmds \(version)")
            return 0
        }
        // Allow global options before the command: `cmds --json ls`.
        var leading: [String] = []
        while let first = words.first, first.hasPrefix("--"), first != "--" {
            leading.append(words.removeFirst())
            if first == "--socket", !words.isEmpty { leading.append(words.removeFirst()) }
        }
        guard let (command, rest) = lookup(words) else {
            if let first = words.first, groups.contains(first) {
                printError("\(first): missing or unknown subcommand\n" + groupHelp(first))
            } else {
                printError("unknown command: \(words.first ?? "")  (see `cmds --help`)")
            }
            return CLIError.Code.usage.rawValue
        }
        do {
            let args = try Arguments(leading + rest, options: command.options, flags: command.flags, aliases: command.aliases)
            if args.has("help") {
                print(command.help, terminator: "")
                return 0
            }
            try command.run(Context(args: args, environment: environment))
            return 0
        } catch let error as CLIError {
            printError(error.message)
            return error.code.rawValue
        } catch {
            printError("\(error)")
            return CLIError.Code.failure.rawValue
        }
    }

    static var groups: Set<String> { Set(commands.compactMap { $0.name.split(separator: " ").count > 1 ? String($0.name.split(separator: " ")[0]) : nil }) }

    static func lookup(_ words: [String]) -> (Command, [String])? {
        if words.count >= 2, let command = commands.first(where: { $0.name == "\(words[0]) \(words[1])" }) {
            return (command, Array(words.dropFirst(2)))
        }
        if let first = words.first, let command = commands.first(where: { $0.name == first }) {
            return (command, Array(words.dropFirst()))
        }
        return nil
    }

    static func groupHelp(_ group: String) -> String {
        let entries = commands.filter { $0.name.hasPrefix(group + " ") }
        return "usage:\n" + entries.map { "  cmds \($0.usage)\n" }.joined()
    }

    static var overview: String {
        let width = commands.map(\.name.count).max() ?? 0
        let list = commands.map { "  \($0.name.padding(toLength: width + 2, withPad: " ", startingAt: 0))\($0.summary)\n" }.joined()
        return """
            cmds — control the cmds terminal app from the command line

            usage: cmds <command> [options] [--json]

            Commands:
            \(list)
            Inside a cmds terminal, commands target the current pane/workspace (CMDS_PANE_ID,
            CMDS_WORKSPACE_ID) unless --pane / --workspace is given. Outside, they target the
            focused pane of the selected workspace.

            Run `cmds help <command>` or `cmds <command> --help` for details.
            Exit codes: 0 ok, 1 request failed, 2 usage error, 3 app not reachable.

            """
    }
}
