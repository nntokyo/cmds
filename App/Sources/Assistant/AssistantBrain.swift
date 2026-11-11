import CmdsCore
import Foundation
import FoundationModels
import os

private let brainLog = Logger(subsystem: "tokyo.n-n.cmds", category: "assistant")

/// The assistant's free answers and summaries (#243). On-device first: Apple's Foundation Models
/// (`SystemLanguageModel.default`, never Private Cloud Compute). `claude -p` only for a summary the user asked for
/// "in detail" (no tools at all: the screen text is untrusted) and for a web question (`webAnswer`: only WebSearch and
/// WebFetch, only the user's own words): headless, bounded in time, without any permission-skipping flag, no MCP
/// servers, in an empty temporary folder.
@available(macOS 26.0, *)
enum AssistantBrain {
    /// How long the on-device model may take.
    static let modelTimeout: Duration = .seconds(20)
    /// How long `claude -p` may take before it is stopped.
    static let claudeTimeout: TimeInterval = 90
    /// Screen text handed to a model, from the end.
    static let maxScreenCharacters = 6000

    static var modelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    private static func instructions(_ language: AssistantLanguage, web: Bool = false) -> String {
        let base = """
        You are the voice assistant of cmds, a terminal app where AI coding agents work. Your answers are spoken aloud: \
        answer in \(language.name), in at most three short sentences, plain text without Markdown, lists or code. \
        You cannot run commands or change anything; never claim you did.
        """
        guard web else { return base }
        return base + """
         You have no internet. If answering needs current or outside information you do not have (weather, news, \
        prices, schedules, recent events, facts you are unsure of) or the user asks you to search, answer exactly \
        \(AssistantWeb.marker) and nothing else: the question is then searched on the web.
        """
    }

    /// A free question, with the workspaces' status as context. `web`: the model answers `AssistantWeb.marker` when it
    /// needs the web (the caller then asks Claude).
    static func answer(_ question: String, status: String, language: AssistantLanguage, web: Bool = false) async throws -> String {
        try await respond(prompt: "Workspaces now: \(status)\n\nQuestion: \(question)", instructions: instructions(language, web: web))
    }

    /// What a workspace's agent is doing, from the facts and the end of its screen.
    static func summarize(facts: String, screen: String, language: AssistantLanguage) async throws -> String {
        let prompt = """
        Facts: \(facts)

        The end of its terminal screen:
        ---
        \(String(screen.suffix(maxScreenCharacters)))
        ---
        In one or two sentences: what is the agent doing or asking now?
        """
        return try await respond(prompt: prompt, instructions: instructions(language))
    }

    private static func respond(prompt: String, instructions: String) async throws -> String {
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await session.respond(to: prompt).content }
            group.addTask {
                try await Task.sleep(for: modelTimeout)
                throw CancellationError()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: claude -p

    enum ClaudeFailure: Error {
        case notFound
        case failed(Int32)
        case timedOut
    }

    /// Where `claude` usually lives (the app's own PATH does not have the user's shell additions).
    private static func claudeExecutable() -> String? {
        let home = NSHomeDirectory()
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `claude -p` gets no tools at all (`--tools ""`) and no MCP servers (`--strict-mcp-config` without a config): the
    /// screen text it summarises is untrusted and could ask for anything, and a summary of standard input needs none.
    static let toolArguments = ["--tools", "", "--strict-mcp-config"]

    /// A longer summary by Claude Code, run headless. The screen text goes in on standard input.
    static func detailedSummary(facts: String, screen: String, language: AssistantLanguage) async throws -> String {
        let prompt = """
        Read-only task: do not run commands, edit files or use tools. Standard input is the end of a terminal screen \
        where an AI coding agent works (\(facts)). Summarise for the user, to be read aloud in \(language.name): what \
        the agent has done, what it is doing or asking now, and anything that needs the user's attention. At most six \
        sentences, plain text, no Markdown.
        """
        brainLog.info("claude -p summary started")
        return try await runClaude(arguments: ["-p", prompt, "--output-format", "text"] + toolArguments,
                                   input: String(screen.suffix(maxScreenCharacters * 2)))
    }

    /// A web question gets the web tools only, still no MCP servers. `--allowedTools` lets those two run without a
    /// permission prompt (nobody could answer one); no other tool exists to allow.
    static let webToolArguments = ["--tools", "WebSearch,WebFetch", "--allowedTools", "WebSearch,WebFetch", "--strict-mcp-config"]

    /// The `claude -p` arguments for a web question: only the user's own words go in (never screen text), with the
    /// date and time, the time zone and the locale, for "tomorrow" and "here".
    static func webArguments(question: String, language: AssistantLanguage, now: Date = Date(),
                             timeZone: TimeZone = .current, locale: Locale = .current) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        let prompt = """
        You are the voice assistant of cmds, a Mac terminal app. Answer the user's spoken question below. Search the \
        web when the answer needs current or outside information. Now: \(formatter.string(from: now)), time zone \
        \(timeZone.identifier), the user's locale \(locale.identifier). The answer is read aloud: write it in \
        \(language.name), at most four short sentences, plain text without Markdown, lists, URLs, sources or emoji. If \
        you assumed a place or a date, say which. Do not run commands or read or write files.

        The user's question: \(question)
        """
        return ["-p", prompt, "--output-format", "text"] + webToolArguments
    }

    /// A free question answered by Claude Code with web search, run headless like `detailedSummary`.
    static func webAnswer(question: String, language: AssistantLanguage) async throws -> String {
        brainLog.info("claude -p web answer started")
        let text = try await runClaude(arguments: webArguments(question: question, language: language), input: nil)
        let spoken = AssistantWeb.speakable(text)
        guard !spoken.isEmpty else { throw ClaudeFailure.failed(0) }
        return spoken
    }

    /// How long the interpreter may take (it is asked before anything is said).
    static let interpreterTimeout: TimeInterval = 30

    /// The interpreter's arguments: no tools, no MCP servers, the small model (it only fills in one JSON object).
    static func interpreterArguments(utterance: String, world: AssistantWorld, language: AssistantLanguage) -> [String] {
        let prompt = AssistantInterpretation.prompt(utterance: utterance, world: world, language: language.name)
        return ["-p", prompt, "--output-format", "text", "--model", "haiku"] + toolArguments
    }

    /// A free command turned into one JSON object (`AssistantInterpretation`) by `claude -p` without any tools. It gets
    /// only the utterance and the workspaces' names, agents and states, never screen text.
    static func interpret(utterance: String, world: AssistantWorld, language: AssistantLanguage) async throws -> String {
        brainLog.info("claude -p interpreter started")
        return try await runClaude(arguments: interpreterArguments(utterance: utterance, world: world, language: language),
                                   input: nil, timeout: interpreterTimeout)
    }

    /// Runs `claude` in an empty temporary folder, stopped after `timeout`: its standard output, trimmed.
    private static func runClaude(arguments: [String], input: String?, timeout: TimeInterval = claudeTimeout) async throws -> String {
        guard let executable = claudeExecutable() else { throw ClaudeFailure.notFound }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-assistant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        let stdin = Pipe()
        let output = Pipe()
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var done = false
            let finish: (Result<String, Error>) -> Void = { result in
                lock.lock()
                defer { lock.unlock() }
                guard !done else { return }
                done = true
                continuation.resume(with: result)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()
                    finish(.failure(ClaudeFailure.timedOut))
                }
            }
            DispatchQueue.global().async {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0, !text.isEmpty {
                    finish(.success(text))
                } else {
                    finish(.failure(ClaudeFailure.failed(process.terminationStatus)))
                }
            }
        }
    }
}
