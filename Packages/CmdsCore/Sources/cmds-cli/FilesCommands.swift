import CmdsCore
import Foundation

// `cmds files` and `cmds transfers`: files panes on this Mac or on SSH hosts, and the transfer queue
// (docs/guide/files.md, docs/reference/cli.md).
extension CLI {
    static let filesUsage = "cmds files [--pane P] [--down] [--no-focus] [PATH | HOST:PATH]"

    static let filesCommands: [Command] = [
        Command(name: "files", usage: "files [--pane P] [--down] [--no-focus] [PATH | HOST:PATH]",
                summary: "List a folder (on this Mac or an SSH host) in a files pane split to the right of a pane.",
                details: """
                    PATH defaults to the current directory; relative paths are resolved against it, and a file's folder
                    is listed with the file selected. HOST:PATH lists a folder on an SSH host over SFTP, with your ssh
                    (~/.ssh/config, keys, agent; never a password): HOST as for `cmds new --ssh`, PATH absolute, ~/…,
                    relative to the remote home, or empty (home). A colon before any / makes it remote, as with scp:
                    write ./a:b for a local name with a colon. Connection errors show in the pane.
                    --pane naming a files pane (of the same host for HOST:PATH) shows the folder in that pane instead of
                    splitting. --down splits below, --no-focus keeps the keyboard in the current pane.
                    Not available from SSH panes. Prints the files pane id.
                    """,
                options: ["pane"], flags: ["down", "no-focus"]) { ctx in
            try ctx.args.expectPositionals(0...1, usage: filesUsage)
            let argument = ctx.args.positionals.first ?? "."
            let location: FileLocation
            do {
                location = try FileLocation.parse(argument)
            } catch {
                throw CLIError.usage("\(error)")
            }
            var params: [String: JSONValue?] = [
                "pane": ctx.pane.json,
                "direction": ctx.args.has("down") ? "down" : nil,
                "focus": ctx.args.has("no-focus") ? false : nil,
            ]
            if let host = location.host {
                params["host"] = .string(host)
                params["path"] = .string(location.path)
            } else {
                let path = absolutePath(argument)
                guard FileManager.default.fileExists(atPath: path) else {
                    throw CLIError.failure("no such file or folder: \(argument)")
                }
                params["path"] = .string(path)
            }
            let result = try ctx.call("files.open", params)
            ctx.printResult(result, field: "id")
        },
        Command(name: "transfers", usage: "transfers [list]",
                summary: "List the transfer queue: copies and moves to and from SSH hosts.",
                details: """
                    One line per job: id, state, what goes where, progress, and its counts; failed items follow.
                    States: queued, running, paused, waiting (for an answer about a name conflict, in the app), done,
                    failed, cancelled. Subcommands: pause, resume, cancel, retry ID; clear removes finished jobs.
                    """) { ctx in
            try ctx.args.expectPositionals(0...1, usage: "cmds transfers [list]")
            if let word = ctx.args.positionals.first, word != "list" {
                throw CLIError.usage("unknown subcommand: \(word)\n" + groupHelp("transfers"))
            }
            let result = try ctx.call("transfer.list")
            if ctx.json { return ctx.printJSON(result) }
            let jobs = try perform { try result.decode([TransferInfo].self) }
            if jobs.isEmpty { return print("no transfers") }
            print(jobs.map(Format.transfer).joined(separator: "\n"))
        },
    ] + ["pause", "resume", "cancel", "retry"].map { verb in
        Command(name: "transfers \(verb)", usage: "transfers \(verb) ID", summary: "\(verb.capitalized) a transfer.") { ctx in
            try ctx.args.expectPositionals(1...1, usage: "cmds transfers \(verb) ID")
            guard let id = Int(ctx.args.positionals[0]), id > 0 else { throw CLIError.usage("ID must be a transfer number") }
            try ctx.call("transfer.\(verb)", ["id": .number(Double(id))])
        }
    } + [
        Command(name: "transfers clear", usage: "transfers clear", summary: "Remove finished transfers from the list.") { ctx in
            try ctx.args.expectPositionals(0...0, usage: "cmds transfers clear")
            try ctx.call("transfer.clear")
        },
    ]
}

extension Format {
    /// `3  running  copy  2 items → home:/srv  1.2 MB of 4 MB  (a.txt)`, then a line per failure.
    static func transfer(_ job: TransferInfo) -> String {
        let what = job.sources.count == 1 ? job.sources[0] : "\(job.sources.count) items"
        let arrow: String
        switch job.direction {
        case .both?: arrow = "↔"
        case .rightToLeft?: arrow = "←"
        default: arrow = "→"
        }
        var line = "\(job.id)  \(job.state.rawValue)  \(job.mode.rawValue)  \(what) \(arrow) \(job.destination)"
        if job.bytesTotal > 0 { line += "  \(bytes(job.bytesDone)) of \(bytes(job.bytesTotal))" }
        if let current = job.current, job.state == .running { line += "  (\(current))" }
        if let asking = job.asking { line += "  asking about \(asking)" }
        var counts: [String] = []
        if job.copied > 0 { counts.append("\(job.copied) copied") }
        if job.moved > 0 { counts.append("\(job.moved) moved") }
        if job.skipped > 0 { counts.append("\(job.skipped) skipped") }
        if let trashed = job.trashed, trashed > 0 { counts.append("\(trashed) moved to the Trash") }
        // `failures` lists at most 50; `failed` counts them all (nil from an app that does not send it).
        let failed = job.failed ?? job.failures.count
        if failed > 0 { counts.append("\(failed) failed") }
        if !counts.isEmpty { line += "  " + counts.joined(separator: ", ") }
        if let error = job.error { line += "\n    error: \(oneLine(error))" }
        for failure in job.failures { line += "\n    \(failure.path): \(oneLine(failure.message))" }
        return line
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
