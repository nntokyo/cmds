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
        Command(name: "files compare", usage: "files compare [--to-right | --to-left | --both] [--delete] [--conflicts RULE] [--hidden] [--same] LEFT RIGHT",
                summary: "Compare two folders (on this Mac or SSH hosts) and show what a sync would do.",
                details: """
                    LEFT and RIGHT are paths or HOST:PATH, as for `cmds files`. Folders are compared recursively by
                    name, size and date (to the second); symbolic links are listed but never followed or synced, and
                    hidden items (names starting with a dot) are left out unless --hidden. --same lists identical items
                    too. Each line: the planned action (→ copy to the right, ← copy to the left, ✕L / ✕R to the Trash
                    on that side, ? an unsettled conflict, blank nothing), the status, the path.
                    The plan is for --to-right, --to-left or --both (default). One-way syncs copy new and modified
                    items and, with --delete, move items only on the target side to its Trash. Two-way syncs copy
                    missing items both ways and never delete; items that differ are conflicts settled by --conflicts:
                    newer (default; equal dates stay unsettled), left, right or skip.
                    Not available from SSH panes.
                    """,
                options: ["conflicts"], flags: ["to-right", "to-left", "both", "delete", "hidden", "same"]) { ctx in
            let usage = "cmds files compare [--to-right | --to-left | --both] [--delete] [--conflicts RULE] [--hidden] [--same] LEFT RIGHT"
            try ctx.args.expectPositionals(2...2, usage: usage)
            var params = try folderSyncParams(ctx, requireDirection: false)
            params["same"] = ctx.args.has("same") ? true : nil
            let result = try ctx.call("files.compare", params, timeout: 600)
            if ctx.json { return ctx.printJSON(result) }
            let info = try perform { try result.decode(FolderCompareInfo.self) }
            print(Format.folderCompare(info))
        },
        Command(name: "files sync", usage: "files sync (--to-right | --to-left | --both) [--delete] [--conflicts RULE] [--hidden] LEFT RIGHT",
                summary: "Sync two folders through the transfer queue (compare first; see `cmds files compare`).",
                details: """
                    Compares LEFT and RIGHT again and queues what the plan says as one transfer (`cmds transfers`):
                    --to-right or --to-left copies new and modified items one way (--delete also moves items only on
                    the target side to its Trash); --both copies missing items both ways and settles items that differ
                    with --conflicts (newer, default; left; right; skip). Replaced items go to the Trash of their side
                    first; nothing is ever deleted. An item that changed between the comparison and its turn is left as
                    it is. Prints the transfer id, or "nothing to sync". Refused when the comparison was cut short
                    (too many items). Not available from SSH panes.
                    """,
                options: ["conflicts"], flags: ["to-right", "to-left", "both", "delete", "hidden"]) { ctx in
            let usage = "cmds files sync (--to-right | --to-left | --both) [--delete] [--conflicts RULE] [--hidden] LEFT RIGHT"
            try ctx.args.expectPositionals(2...2, usage: usage)
            let result = try ctx.call("files.sync", try folderSyncParams(ctx, requireDirection: true), timeout: 600)
            if ctx.json { return ctx.printJSON(result) }
            let info = try perform { try result.decode(FolderCompareInfo.self) }
            guard let transfer = info.transfer else { return print("nothing to sync") }
            let s = info.summary
            print("transfer \(transfer): \(s.toRight) → right, \(s.toLeft) ← left, \(s.trashLeft + s.trashRight) to the Trash"
                  + (s.unsettled > 0 ? ", \(s.unsettled) conflicts left as they are" : ""))
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

extension CLI {
    /// `left`, `right`, `direction`, `delete`, `conflicts`, `hidden` for `files.compare` / `files.sync`.
    static func folderSyncParams(_ ctx: Context, requireDirection: Bool) throws -> [String: JSONValue?] {
        func location(_ argument: String) throws -> String {
            let parsed: FileLocation
            do {
                parsed = try FileLocation.parse(argument)
            } catch {
                throw CLIError.usage("\(error)")
            }
            if parsed.isRemote { return parsed.description }
            let path = absolutePath(argument)
            guard FileCheck.isFolder(path) else { throw CLIError.failure("not a folder: \(argument)") }
            return path
        }
        let directions = [("to-right", "leftToRight"), ("to-left", "rightToLeft"), ("both", "both")]
            .filter { ctx.args.has($0.0) }
        guard directions.count <= 1 else { throw CLIError.usage("give one of --to-right, --to-left, --both") }
        if requireDirection, directions.isEmpty { throw CLIError.usage("give --to-right, --to-left or --both") }
        let conflicts = ctx.args[option: "conflicts"]
        if let conflicts, FolderSync.ConflictRule(rawValue: conflicts) == nil {
            throw CLIError.usage("--conflicts must be newer, left, right or skip")
        }
        return [
            "left": .string(try location(ctx.args.positionals[0])),
            "right": .string(try location(ctx.args.positionals[1])),
            "direction": .string(directions.first?.1 ?? "both"),
            "delete": ctx.args.has("delete") ? true : nil,
            "conflicts": conflicts.map(JSONValue.string),
            "hidden": ctx.args.has("hidden") ? true : nil,
        ]
    }
}

private enum FileCheck {
    static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

extension Format {
    /// `left` / `right` lines, one line per entry (`→ modified      index.html`), then the plan's counts.
    static func folderCompare(_ info: FolderCompareInfo) -> String {
        var lines = ["left   \(info.left)", "right  \(info.right)"]
        for entry in info.entries {
            let action: String
            switch entry.action {
            case .toRight?: action = "→ "
            case .toLeft?: action = "← "
            case .trashLeft?: action = "✕L"
            case .trashRight?: action = "✕R"
            case nil: action = entry.conflict ? "? " : "  "
            }
            let status: String
            switch entry.status {
            case .leftOnly: status = "left only"
            case .rightOnly: status = "right only"
            case .modified:
                status = entry.newer == .left ? "left newer" : entry.newer == .right ? "right newer" : "modified"
            case .same: status = "same"
            case .skipped: status = "link (skipped)"
            case .unreadable: status = "unreadable"
            }
            let folder = (entry.left ?? entry.right)?.kind == "folder" ? "/" : ""
            var line = "\(action) \(status.padding(toLength: 14, withPad: " ", startingAt: 0)) \(entry.path)\(folder)"
            if let error = entry.error { line += "  (\(oneLine(error)))" }
            lines.append(line)
        }
        if info.entries.isEmpty { lines.append("no differences") }
        let s = info.summary
        var plan = "plan (\(info.direction.rawValue)): \(s.toRight) → right, \(s.toLeft) ← left, "
            + "\(s.trashLeft + s.trashRight) to the Trash"
        if s.unsettled > 0 { plan += ", \(s.unsettled) conflicts unsettled" }
        lines.append(plan)
        if info.truncated { lines.append("too many items: the comparison stopped after \(info.itemsRead); it cannot be synced") }
        return lines.joined(separator: "\n")
    }

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
