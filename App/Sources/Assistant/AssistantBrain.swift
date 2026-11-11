import CmdsCore
import Foundation
import FoundationModels
import os

private let brainLog = Logger(subsystem: "tokyo.n-n.cmds", category: "assistant")

/// The assistant's free answers and summaries (#243). On-device first: Apple's Foundation Models
/// (`SystemLanguageModel.default`, never Private Cloud Compute). `claude -p` only for a summary the user asked for
/// "in detail" (no tools at all: the screen text is untrusted) and for a web question (`webAnswer`: only WebSearch and
/// WebFetch, only the user's own words): headless, bounded in time, without any permission-skipping flag, no MCP
/// servers, in an empty temporary folder, isolated from the user's Claude Code setup and stopped when the request is
/// cancelled. Prompts and arguments: `AssistantClaude`.
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

    /// A free question, with the workspaces' status as context. `web`: the model answers `AssistantWeb.marker` when it
    /// needs the web (the caller then asks Claude).
    static func answer(_ question: String, status: String, language: AssistantLanguage, web: Bool = false) async throws -> String {
        try await respond(prompt: "Workspaces now: \(status)\n\nQuestion: \(question)", instructions: AssistantClaude.modelInstructions(language: language.name, web: web))
    }

    /// What a workspace's agent is doing, from the facts and the end of its screen: one short sentence.
    static func summarize(facts: String, screen: String, language: AssistantLanguage) async throws -> String {
        let prompt = AssistantClaude.summaryPrompt(facts: facts, screen: String(screen.suffix(maxScreenCharacters)))
        return try await respond(prompt: prompt, instructions: AssistantClaude.modelInstructions(language: language.name, web: false))
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

    /// A short summary by Claude Code, run headless (`AssistantClaude`: isolated, no tools). The screen text goes in on
    /// standard input.
    static func detailedSummary(facts: String, screen: String, language: AssistantLanguage) async throws -> String {
        brainLog.info("claude -p summary started")
        return try await runClaude(arguments: AssistantClaude.detailedSummaryArguments(facts: facts, language: language.name),
                                   input: String(screen.suffix(maxScreenCharacters * 2)))
    }

    /// A free question answered by Claude Code with web search only, run headless like `detailedSummary`.
    static func webAnswer(question: String, language: AssistantLanguage) async throws -> String {
        brainLog.info("claude -p web answer started")
        let text = try await runClaude(arguments: AssistantClaude.webArguments(question: question, language: language.name), input: nil)
        let spoken = AssistantWeb.speakable(text)
        guard !spoken.isEmpty else { throw ClaudeFailure.failed(0) }
        return spoken
    }

    /// How long the interpreter may take (it is asked before anything is said).
    static let interpreterTimeout: TimeInterval = 30

    /// A free command turned into one JSON object (`AssistantInterpretation`) by `claude -p` without any tools. It gets
    /// only the utterance and the workspaces' names, agents and states, never screen text.
    static func interpret(utterance: String, world: AssistantWorld, language: AssistantLanguage) async throws -> String {
        brainLog.info("claude -p interpreter started")
        return try await runClaude(arguments: AssistantClaude.interpreterArguments(utterance: utterance, world: world, language: language.name),
                                   input: nil, timeout: interpreterTimeout)
    }

    /// Runs `claude` in an empty temporary folder, stopped after `timeout`: its standard output, trimmed. The folder is
    /// always the same one (no tool can write to it): Claude Code still makes an (empty) project folder under
    /// `~/.claude/projects` for its working directory, and so makes only one.
    private static func runClaude(arguments: [String], input: String?, timeout: TimeInterval = claudeTimeout) async throws -> String {
        guard let executable = claudeExecutable() else { throw ClaudeFailure.notFound }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-assistant")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        // Without cmds' pane variables: no hook may take the assistant's own call for an agent in a pane.
        process.environment = AssistantClaude.environment(ProcessInfo.processInfo.environment)
        let stdin = Pipe()
        let output = Pipe()
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        // The user moved on (a new request, barge-in, off): the process is stopped, its answer never used.
        let running = RunningProcess(process)
        return try await withTaskCancellationHandler {
            try await wait(for: process, output: output, timeout: timeout)
        } onCancel: {
            running.terminate()
        }
    }

    /// A process to stop from a cancellation handler.
    private final class RunningProcess: @unchecked Sendable {
        private let process: Process
        init(_ process: Process) { self.process = process }
        func terminate() {
            if process.isRunning { process.terminate() }
        }
    }

    private static func wait(for process: Process, output: Pipe, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
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
