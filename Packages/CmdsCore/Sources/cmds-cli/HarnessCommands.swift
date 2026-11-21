import CmdsCore
import Foundation

// `cmds harness report|suggest|skill|review`: growing the Claude Code setup from what ~/.claude holds
// (docs/guide/ai-agents.md "Growing the harness"; logic and safety rules in CmdsCore/ClaudeHarness.swift).
extension CLI {
    /// `<support>/Harness`: proposals, reports and backups (never inside ~/.claude).
    static func harnessFolder(_ ctx: Context) -> URL {
        CmdsEnv.supportDirectoryURL(environment: ctx.environment).appendingPathComponent("Harness", isDirectory: true)
    }

    static func stamp(_ date: Date = Date(), format: String = "yyyyMMdd-HHmmss") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    /// Writes `text` to `name` in the harness folder (0600) and returns the file.
    static func writeHarnessFile(_ ctx: Context, _ name: String, _ text: String) throws -> URL {
        let folder = harnessFolder(ctx)
        let url = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Data(text.utf8).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw CLIError.failure("cannot write \(url.path): \(error.localizedDescription)")
        }
        return url
    }

    /// Shows `file` in a preview pane beside this terminal (`--open`); quietly nothing when the app is not there.
    static func openInPreview(_ ctx: Context, _ file: URL, format: String?) {
        guard ctx.args.has("open") else { return }
        _ = try? ctx.call("pane.open_file", ["pane": ctx.pane.json, "path": .string(file.path),
                                             "format": format.map { .string($0) }, "focus": false])
    }

    /// `claude -p` with `prompt` on stdin (no tools, isolated); its answer, trimmed.
    static func runClaude(_ ctx: Context, prompt: String) throws -> String {
        let model = ctx.args[option: "model"] ?? ClaudeHarness.defaultModel
        let path = (ctx.environment["PATH"] ?? "/usr/bin:/bin") + ":" + NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin"
        guard let claude = path.split(separator: ":").map({ String($0) + "/claude" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CLIError.failure("claude (Claude Code) was not found on PATH")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ClaudeHarness.claudeArguments(model: model)
        process.environment = AssistantClaude.environment(ctx.environment)
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        printError("asking Claude (\(model))…")
        do { try process.run() } catch { throw CLIError.failure("cannot run claude: \(error.localizedDescription)") }
        let writer = Thread {
            input.fileHandleForWriting.write(Data(prompt.utf8))
            try? input.fileHandleForWriting.close()
        }
        writer.start()
        var collected = Data()
        let reader = Thread { collected = output.fileHandleForReading.readDataToEndOfFile() }
        reader.start()
        let deadline = Date(timeIntervalSinceNow: 600)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if process.isRunning {
            process.terminate()
            throw CLIError.failure("claude did not answer within 10 minutes")
        }
        while reader.isExecuting { Thread.sleep(forTimeInterval: 0.05) }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw CLIError.failure("claude failed: \(message.suffix(500))")
        }
        var text = String(decoding: collected, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // A code fence around the whole answer despite the prompt.
        if text.hasPrefix("```"), text.hasSuffix("```") {
            text = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().dropLast().joined(separator: "\n")
        }
        guard !text.isEmpty else { throw CLIError.failure("claude gave no answer") }
        return text + "\n"
    }

    /// Asks on the terminal (`--yes`: yes); false without a terminal.
    static func confirm(_ ctx: Context, _ question: String) -> Bool {
        if ctx.args.has("yes") { return true }
        guard isatty(0) != 0 else {
            printError("not applied (no terminal to ask; pass --yes to apply)")
            return false
        }
        print("\(question) [y/N] ", terminator: "")
        fflush(stdout)
        return ["y", "yes"].contains((readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// The project folder under ~/.claude/projects for `--project DIR` (default: this directory).
    static func harnessProject(_ ctx: Context, claude: URL) throws -> (dir: String, folder: URL) {
        let dir = absolutePath(ctx.args[option: "project"] ?? FileManager.default.currentDirectoryPath)
        let folder = claude.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(ClaudeHarness.projectFolderName(dir), isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw CLIError.failure("Claude Code has no sessions for \(dir) (\(folder.path)); give --project DIR")
        }
        return (dir, folder)
    }

    static func days(_ ctx: Context) throws -> Int {
        let days = try ctx.args.int("days") ?? 30
        guard (1...365).contains(days) else { throw CLIError.usage("--days must be 1 to 365") }
        return days
    }

    static let harnessCommands: [Command] = [
        Command(name: "harness report", usage: "harness report [--days N] [--open]",
                summary: "Overview of what ~/.claude holds: sessions, prompts and models per project, memory, skills, MCP servers.",
                details: """
                    Reads only (session logs, memory, settings); nothing leaves the Mac. Writes a Markdown report to
                    cmds' support folder (Harness/) and prints its path; --open shows it beside this terminal.
                    --days N (default 30).
                    """,
                options: ["days"], flags: ["open"]) { ctx in
            try ctx.args.expectPositionals(0...0, usage: "cmds harness report [--days N] [--open]")
            let days = try days(ctx)
            let overview = ClaudeHarness.scan(claudeFolder: ClaudeHarness.claudeFolder(environment: ctx.environment), days: days)
            if ctx.json { return ctx.printJSON(try JSONValue.from(overview)) }
            let file = try writeHarnessFile(ctx, "report-\(stamp(format: "yyyyMMdd")).md", ClaudeHarness.overviewMarkdown(overview, days: days))
            print(file.path)
            openInPreview(ctx, file, format: "markdown")
        },
        Command(name: "harness suggest",
                usage: "harness suggest [--project DIR | --global] [--days N] [--model M] [--instruction TEXT] [--yes] [--open]",
                summary: "Ask Claude for an improved CLAUDE.md from your recent prompts and memory; apply it after seeing the diff.",
                details: """
                    Sends the project's recent prompts (one line each, at most 40,000 characters, secrets masked) and
                    memory notes with the current CLAUDE.md to `claude -p` (no tools, without your settings, hooks or MCP
                    servers). Writes the proposal and its diff to cmds' support folder (Harness/), prints the diff,
                    and asks before replacing the file (the old one is backed up to Harness/backups first). --global:
                    ~/.claude/CLAUDE.md from every project's prompts. --open shows the diff beside this terminal.
                    """,
                options: ["project", "days", "model", "instruction"], flags: ["global", "yes", "open"]) { ctx in
            try ctx.args.expectPositionals(0...0, usage: "cmds harness suggest [options]")
            let claude = ClaudeHarness.claudeFolder(environment: ctx.environment)
            let since = Date().addingTimeInterval(-Double(try days(ctx)) * 86_400)
            let target: URL
            var digest = "", memory = ""
            if ctx.args.has("global") {
                if ctx.args[option: "project"] != nil { throw CLIError.usage("give --project or --global, not both") }
                target = claude.appendingPathComponent("CLAUDE.md")
                let projects = claude.appendingPathComponent("projects", isDirectory: true)
                for name in ((try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []).sorted() {
                    digest += ClaudeHarness.digest(projectFolder: projects.appendingPathComponent(name), since: since,
                                                   prefix: "[\(name)] ", maxCharacters: max(0, 40_000 - digest.count) / 2)
                }
            } else {
                let project = try harnessProject(ctx, claude: claude)
                target = URL(fileURLWithPath: project.dir).appendingPathComponent("CLAUDE.md")
                digest = ClaudeHarness.digest(projectFolder: project.folder, since: since)
                memory = ClaudeHarness.memory(projectFolder: project.folder)
            }
            guard !digest.isEmpty || !memory.isEmpty else { throw CLIError.failure("no prompts or memory in that period") }
            let current = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
            let proposal = try runClaude(ctx, prompt: ClaudeHarness.suggestPrompt(current: ClaudeHarness.redact(current), digest: digest,
                                                                                 memory: memory, instruction: ctx.args[option: "instruction"]))
            let base = "suggest-\(stamp())"
            let proposed = try writeHarnessFile(ctx, "\(base).CLAUDE.md", proposal)
            let old = try writeHarnessFile(ctx, "\(base).current.CLAUDE.md", current)
            let diff = Process()
            diff.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
            diff.arguments = ["-u", "--label", "a/CLAUDE.md", "--label", "b/CLAUDE.md", old.path, proposed.path]
            let pipe = Pipe()
            diff.standardOutput = pipe
            try? diff.run()
            let diffText = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            diff.waitUntilExit()
            guard !diffText.isEmpty else { return print("no change suggested") }
            let diffFile = try writeHarnessFile(ctx, "\(base).diff", diffText)
            print(diffText)
            openInPreview(ctx, diffFile, format: "diff")
            guard confirm(ctx, "Replace \(target.path) with this?") else { return print("proposal kept in \(proposed.path)") }
            if ClaudeHarness.redact(proposal) != proposal {
                printError("the proposal contains something that looks like a secret; check \(proposed.path) and copy it yourself")
                throw CLIError.failure("not applied")
            }
            do {
                let backup = try ClaudeHarness.applyFile(proposal, to: target, backups: harnessFolder(ctx).appendingPathComponent("backups"))
                print("applied to \(target.path)" + (backup.map { " (backup: \($0.path))" } ?? ""))
            } catch {
                throw CLIError.failure("cannot write \(target.path): \(error.localizedDescription)")
            }
        },
        Command(name: "harness skill", usage: "harness skill [--project DIR] [--files A.md,B.md] [--model M] [--yes] [--open]",
                summary: "Ask Claude to turn a project's auto-memory into a skill; install it into ~/.claude/skills after a look.",
                details: """
                    Sends the project's memory notes (secrets masked; --files picks some) to `claude -p` (no tools, isolated)
                    and writes the SKILL.md it proposes to cmds' support folder (Harness/skills/NAME/). Asks before copying
                    it to ~/.claude/skills/NAME/ (an existing skill there is backed up first). --open shows it.
                    """,
                options: ["project", "files", "model"], flags: ["yes", "open"]) { ctx in
            try ctx.args.expectPositionals(0...0, usage: "cmds harness skill [options]")
            let claude = ClaudeHarness.claudeFolder(environment: ctx.environment)
            let project = try harnessProject(ctx, claude: claude)
            let files = ctx.args[option: "files"].map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
            let memory = ClaudeHarness.memory(projectFolder: project.folder, files: files)
            guard !memory.isEmpty else { throw CLIError.failure("no memory notes in \(project.folder.path)/memory") }
            let skill = try runClaude(ctx, prompt: ClaudeHarness.skillPrompt(memory: memory, project: project.dir))
            guard let name = ClaudeHarness.skillName(skill) else {
                let kept = try writeHarnessFile(ctx, "skill-\(stamp()).md", skill)
                throw CLIError.failure("the answer has no usable name in its front matter; kept in \(kept.path)")
            }
            let proposal = try writeHarnessFile(ctx, "skills/\(name)/SKILL.md", skill)
            print(skill)
            print(proposal.path)
            openInPreview(ctx, proposal, format: "markdown")
            let target = claude.appendingPathComponent("skills/\(name)/SKILL.md")
            let exists = FileManager.default.fileExists(atPath: target.path)
            guard confirm(ctx, exists ? "Replace the skill \(name) in \(target.path)?" : "Install it as \(target.path)?") else {
                return print("proposal kept in \(proposal.path)")
            }
            guard ClaudeHarness.redact(skill) == skill else {
                printError("the skill contains something that looks like a secret; check \(proposal.path) and copy it yourself")
                throw CLIError.failure("not installed")
            }
            do {
                let backup = try ClaudeHarness.applyFile(skill, to: target, backups: harnessFolder(ctx).appendingPathComponent("backups"))
                print("installed \(target.path)" + (backup.map { " (backup: \($0.path))" } ?? ""))
            } catch {
                throw CLIError.failure("cannot write \(target.path): \(error.localizedDescription)")
            }
        },
        Command(name: "harness review", usage: "harness review [--date YYYY-MM-DD] [--language L] [--model M] [--open]",
                summary: "A review of one day's Claude Code work (done, open, TODO, harness ideas) from every project's prompts.",
                details: """
                    Default: yesterday. Sends that day's prompts (secrets masked, at most 40,000 characters) to `claude -p`
                    (no tools, isolated) and writes the review to cmds' support folder (Harness/reviews/DATE.md); --open
                    shows it. Schedule it each morning with a schedule that starts a workspace running this command.
                    --language (default: English, e.g. Japanese).
                    """,
                options: ["date", "language", "model"], flags: ["open"]) { ctx in
            try ctx.args.expectPositionals(0...0, usage: "cmds harness review [options]")
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let start: Date
            if let raw = ctx.args[option: "date"] {
                let parser = DateFormatter()
                parser.locale = Locale(identifier: "en_US_POSIX")
                parser.dateFormat = "yyyy-MM-dd"
                guard let date = parser.date(from: raw) else { throw CLIError.usage("--date must be YYYY-MM-DD") }
                start = calendar.startOfDay(for: date)
            } else {
                start = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))!
            }
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            let claude = ClaudeHarness.claudeFolder(environment: ctx.environment)
            let projects = claude.appendingPathComponent("projects", isDirectory: true)
            var digest = ""
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []).sorted() {
                digest += ClaudeHarness.digest(projectFolder: projects.appendingPathComponent(name), since: start, until: end,
                                               prefix: "[\(name)] ", maxCharacters: max(0, 40_000 - digest.count))
            }
            let day = stamp(start, format: "yyyy-MM-dd")
            guard !digest.isEmpty else { throw CLIError.failure("no Claude Code prompts on \(day)") }
            let review = try runClaude(ctx, prompt: ClaudeHarness.reviewPrompt(day: day, digest: digest,
                                                                              language: ctx.args[option: "language"] ?? "English"))
            let file = try writeHarnessFile(ctx, "reviews/\(day).md", "# \(day)\n\n" + review)
            print(file.path)
            openInPreview(ctx, file, format: "markdown")
        },
    ]
}
