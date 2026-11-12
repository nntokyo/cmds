import CmdsCore
import Foundation
import FoundationModels
import os

private let brainLog = Logger(subsystem: "tokyo.n-n.cmds", category: "assistant")

/// The assistant's free answers and summaries (#243). On-device first: Apple's Foundation Models
/// (`SystemLanguageModel.default`, never Private Cloud Compute). `claude -p` only for a summary the user asked for
/// "in detail" (no tools at all: the screen text is untrusted), for a web question (`webAnswer`: only WebSearch and
/// WebFetch, only the user's own words) and for the interpreter of free commands (no tools): headless, bounded in
/// time, without any permission-skipping flag, no MCP servers, isolated from the user's Claude Code setup and stopped
/// when the request is cancelled. Prompts and arguments: `AssistantClaude`; the process: `AssistantClaudeProcess`.
@available(macOS 26.0, *)
enum AssistantBrain {
    typealias Progress = AssistantClaudeProcess.Progress

    static var modelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    // MARK: On-device model

    /// A free question, with the workspaces' status as context. `web`: the model answers `AssistantWeb.marker` when it
    /// needs the web (the caller then asks Claude).
    static func answer(_ question: String, status: String, language: AssistantLanguage, web: Bool = false,
                       progress: Progress? = nil) async throws -> String {
        try await respond(prompt: AssistantClaude.answerPrompt(question: question, status: status),
                          instructions: AssistantClaude.modelInstructions(language: language.name, web: web, actions: true),
                          progress: progress)
    }

    /// What a workspace's agent is doing, from the facts and the end of its screen: one short sentence.
    static func summarize(facts: String, screen: String, language: AssistantLanguage, progress: Progress? = nil) async throws -> String {
        let prompt = AssistantClaude.summaryPrompt(facts: facts, screen: String(screen.suffix(AssistantTuning.maxScreenCharacters)))
        return try await respond(prompt: prompt, instructions: AssistantClaude.modelInstructions(language: language.name, web: false),
                                 progress: progress)
    }

    /// A session warmed up while the user speaks (#248): the model's resources are loaded before it is asked.
    @MainActor private static var warm: LanguageModelSession?

    /// Loads the on-device model ahead of a question (with the instructions of a free answer).
    @MainActor static func prewarm(language: AssistantLanguage) {
        let session = LanguageModelSession(model: SystemLanguageModel.default,
                                           instructions: AssistantClaude.modelInstructions(language: language.name, web: true, actions: true))
        session.prewarm()
        warm = session
    }

    private static func respond(prompt: String, instructions: String, progress: Progress?) async throws -> String {
        progress?(.modelStart, Date())
        defer { progress?(.modelDone, Date()) }
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await session.respond(to: prompt).content }
            group.addTask {
                try await Task.sleep(for: AssistantTuning.modelTimeout)
                throw CancellationError()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: claude -p

    /// A short summary by Claude Code, run headless (`AssistantClaude`: isolated, no tools). The screen text goes in on
    /// standard input. `sentence`: each sentence as it is written (#248: spoken while the rest comes).
    static func detailedSummary(facts: String, screen: String, language: AssistantLanguage, progress: Progress? = nil,
                                sentence: (@Sendable (String) -> Void)? = nil) async throws -> String {
        brainLog.info("claude -p summary started")
        return try await AssistantClaudeProcess.run(
            arguments: AssistantClaude.detailedSummaryArguments(facts: facts, language: language.name),
            input: String(screen.suffix(AssistantTuning.maxDetailedScreenCharacters)), timeout: AssistantTuning.claudeTimeout,
            progress: progress, sentence: sentence)
    }

    /// A free question answered by Claude Code with web search only, run headless like `detailedSummary`.
    static func webAnswer(question: String, language: AssistantLanguage, progress: Progress? = nil) async throws -> String {
        brainLog.info("claude -p web answer started")
        let text = try await AssistantClaudeProcess.run(arguments: AssistantClaude.webArguments(question: question, language: language.name),
                                                        timeout: AssistantTuning.claudeTimeout, progress: progress)
        let spoken = AssistantWeb.speakable(text)
        guard !spoken.isEmpty else { throw AssistantClaudeProcess.Failure.failed(0) }
        return spoken
    }

    /// A free command turned into one JSON object (`AssistantInterpretation`) by `claude -p` without any tools. It gets
    /// only the utterance and the workspaces' names, agents and states, never screen text.
    static func interpret(utterance: String, world: AssistantWorld, language: AssistantLanguage,
                          progress: Progress? = nil) async throws -> String {
        brainLog.info("claude -p interpreter started")
        progress?(.interpreterStart, Date())
        defer { progress?(.interpreterDone, Date()) }
        return try await AssistantClaudeProcess.run(
            arguments: AssistantClaude.interpreterArguments(utterance: utterance, world: world, language: language.name),
            timeout: AssistantTuning.interpreterTimeout, progress: progress)
    }
}
