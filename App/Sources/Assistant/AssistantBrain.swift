import Foundation
import FoundationModels
import os

private let brainLog = Logger(subsystem: "tokyo.n-n.cmds", category: "assistant")

/// The assistant's free answers and summaries (#243). On-device first: Apple's Foundation Models
/// (`SystemLanguageModel.default`, never Private Cloud Compute). `claude -p` only for a summary the user asked for
/// "in detail": headless, bounded in time, without any permission-skipping flag, its tools that write or run things
/// denied, in an empty temporary folder, with a read-only prompt.
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

    private static func instructions(_ language: AssistantLanguage) -> String {
        """
        You are the voice assistant of cmds, a terminal app where AI coding agents work. Your answers are spoken aloud: \
        answer in \(language.name), in at most three short sentences, plain text without Markdown, lists or code. \
        You cannot run commands or change anything; never claim you did.
        """
    }

    /// A free question, with the workspaces' status as context.
    static func answer(_ question: String, status: String, language: AssistantLanguage) async throws -> String {
        try await respond(prompt: "Workspaces now: \(status)\n\nQuestion: \(question)", language: language)
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
        return try await respond(prompt: prompt, language: language)
    }

    private static func respond(prompt: String, language: AssistantLanguage) async throws -> String {
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions(language))
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
        guard let executable = claudeExecutable() else { throw ClaudeFailure.notFound }
        let prompt = """
        Read-only task: do not run commands, edit files or use tools. Standard input is the end of a terminal screen \
        where an AI coding agent works (\(facts)). Summarise for the user, to be read aloud in \(language.name): what \
        the agent has done, what it is doing or asking now, and anything that needs the user's attention. At most six \
        sentences, plain text, no Markdown.
        """
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-assistant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-p", prompt, "--output-format", "text"] + toolArguments
        process.currentDirectoryURL = folder
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        brainLog.info("claude -p summary started")
        try process.run()
        let screenData = Data(String(screen.suffix(maxScreenCharacters * 2)).utf8)
        input.fileHandleForWriting.write(screenData)
        try? input.fileHandleForWriting.close()
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
            DispatchQueue.global().asyncAfter(deadline: .now() + claudeTimeout) {
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
