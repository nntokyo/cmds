import CmdsCore
import Foundation

// `cmds export` / `cmds import`: move workspaces and their agent sessions to another cmds instance
// (docs/reference/cli.md, docs/guide/ai-agents.md "Moving to a new version").
extension CLI {
    static let exportCommand = Command(
        name: "export", usage: "export [-o file] [--legacy]",
        summary: "Write the workspaces and their agent sessions as a JSON bundle (for `cmds import`).",
        details: """
            The bundle (format cmds.workspaces, version 1) has every workspace's title, directory and split layout
            with each pane's kind and location (terminal directory, SSH host and remote directory, browser URL,
            preview file) and the agent session of each terminal pane (agent, session id, directory, host, title,
            model, last seen), plus which workspace is selected. Without -o it goes to stdout. The file is created
            readable by you only.
            An app without `state.export` (older builds) is exported from `workspace.list` and `agent.list` instead;
            --legacy forces that. A legacy export only knows sessions of agents that are running (or, where the app
            has it, remembered by `agent.sessions`), and keeps a workspace title only when it differs from the
            directory name.
            """,
        options: ["output"], flags: ["legacy"], aliases: ["o": "output"]) { ctx in
        try ctx.args.expectPositionals(0...0, usage: "cmds export [-o file] [--legacy]")
        let bundle = try exportBundle(ctx)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try perform { try encoder.encode(bundle) } + Data("\n".utf8)
        let summary = "\(bundle.workspaces.count) workspaces, \(bundle.paneCount) panes, \(bundle.agentSessionCount) agent sessions"
            + (bundle.source?.legacy == true ? " (legacy export)" : "")
        guard let output = ctx.args[option: "output"], output != "-" else {
            FileHandle.standardOutput.write(data)
            if isatty(STDERR_FILENO) != 0 { printError("exported \(summary)") }
            return
        }
        let path = absolutePath(output)
        guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CLIError.failure("cannot write \(output)")
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        print("exported \(summary) to \(path)")
    }

    static let importCommand = Command(
        name: "import", usage: "import <file|-> [--append | --replace] [--resume ask|always|never]",
        summary: "Recreate the workspaces of a `cmds export` bundle and offer their agent sessions for resuming.",
        details: """
            The workspaces are added after the open ones (--append, default) or replace them (--replace closes the
            open workspaces once the imported ones exist). Each terminal pane that had an agent session gets it as
            resume offer, as after a relaunch: --resume ask shows the banner (then `cmds resume --all`), always types
            `claude --resume <id>` / `codex resume <id>` once the pane's shell prompt is ready, never registers
            nothing. Default: the app's View › Resume Agent Sessions on Launch setting. SSH panes are not connected
            until you connect (or resume) them. The bundle is checked first (format, version, paths, hosts, URLs,
            session ids; max 4 MB). Not available from SSH panes.
            """,
        options: ["resume"], flags: ["append", "replace"]) { ctx in
        let usage = "cmds import <file|-> [--append | --replace] [--resume ask|always|never]"
        try ctx.args.expectPositionals(1...1, usage: usage)
        if ctx.args.has("append"), ctx.args.has("replace") { throw CLIError.usage("give either --append or --replace") }
        let resume = try ctx.args[option: "resume"].map { raw -> AgentResumeMode in
            guard let mode = AgentResumeMode(rawValue: raw) else { throw CLIError.usage("--resume must be ask, always or never") }
            return mode
        }
        let data = try readBundleFile(ctx.args.positionals[0])
        let bundle: WorkspaceBundle
        do {
            bundle = try WorkspaceBundle.read(data)
        } catch let error as TransferError {
            throw CLIError.failure(error.message)
        }
        let result = try ctx.call("state.import", [
            "bundle": try perform { try JSONValue.from(bundle) },
            "mode": ctx.args.has("replace") ? "replace" : "append",
            "resume": resume.map { .string($0.rawValue) },
        ], timeout: 120)
        if ctx.json { return ctx.printJSON(result) }
        let outcome = try perform { try result.decode(ImportResult.self) }
        var line = "imported \(outcome.workspaces.count) workspaces (\(outcome.workspaces.joined(separator: ", "))), \(outcome.panes) panes"
        if outcome.closed > 0 { line += "; closed \(outcome.closed) workspaces" }
        print(line)
        for offer in outcome.offers {
            print("\(offer.pane): \(AgentResume.displayName(offer.agent)) session \(offer.sessionID)  \(offer.command ?? "")")
        }
        switch outcome.resume {
        case .ask where !outcome.offers.isEmpty:
            print("resume: offered in each pane (banner); `cmds resume --all` resumes them all")
        case .always where !outcome.offers.isEmpty:
            print("resume: each session resumes once its pane's shell prompt is ready")
        case .never where bundle.agentSessionCount > 0:
            print("resume: never — agent sessions were not registered")
        default:
            break
        }
    }

    /// `state.export`, or the legacy bundle when the app does not have it (or with --legacy).
    private static func exportBundle(_ ctx: Context) throws -> WorkspaceBundle {
        if !ctx.args.has("legacy") {
            do {
                let client = try ctx.connect()
                defer { client.close() }
                let result = try client.call("state.export")
                return try WorkspaceBundle.read(result)
            } catch let error as RPCError where error.code == RPCError.methodNotFound("").code {
                // Older app: fall through to the legacy export.
            } catch let error as TransferError {
                throw CLIError.failure("the app exported an invalid bundle: \(error.message)")
            } catch let error as RPCError {
                throw CLIError.failure(error.message)
            } catch let error as CmdsClient.ClientError {
                if case .notRunning = error { throw CLIError(message: error.description, code: .unavailable) }
                throw CLIError.failure(error.description)
            }
        }
        let workspaces = try ctx.call("workspace.list")
        let agents = optionalCall(ctx, "agent.list")
        let sessions = optionalCall(ctx, "agent.sessions")
        var bundle: WorkspaceBundle
        do {
            bundle = try WorkspaceBundle.legacy(workspaces: workspaces, agents: agents, sessions: sessions)
        } catch let error as TransferError {
            throw CLIError.failure(error.message)
        }
        if let identity = optionalCall(ctx, "system.identify") {
            bundle.source?.version = identity["version"]?.stringValue
            bundle.source?.build = identity["build"]?.stringValue
        }
        return bundle
    }

    /// A method an old app may not have: nil when it fails.
    private static func optionalCall(_ ctx: Context, _ method: String) -> JSONValue? {
        try? ctx.call(method)
    }

    private static func readBundleFile(_ argument: String) throws -> Data {
        let limit = WorkspaceBundle.maxBytes
        let handle: FileHandle
        if argument == "-" {
            handle = .standardInput
        } else {
            guard let file = FileHandle(forReadingAtPath: absolutePath(argument)) else {
                throw CLIError.failure("cannot read \(argument)")
            }
            handle = file
        }
        defer { if argument != "-" { try? handle.close() } }
        // One byte past the limit is enough to know it is too large.
        let data = (try? handle.read(upToCount: limit + 1)) ?? nil ?? Data()
        guard data.count <= limit else { throw CLIError.failure("bundle is too large (max \(limit) bytes)") }
        return data
    }
}
