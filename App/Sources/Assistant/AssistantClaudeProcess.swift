import CmdsCore
import Foundation

/// Runs `claude -p` for the assistant (#243): the arguments come from `AssistantClaude` (isolated from the user's Claude
/// Code setup, tools limited per call), in an empty temporary folder, without cmds' pane variables, stopped after a
/// timeout or when the task asking for it is cancelled. Only its standard output is read.
enum AssistantClaudeProcess {
    /// Hears the stages of a call as they happen (#248: `AssistantTimeline`), from any thread.
    typealias Progress = @Sendable (AssistantTimeline.Stage, Date) -> Void

    enum Failure: Error {
        case notFound
        case failed(Int32)
        case timedOut
    }

    /// Where `claude` usually lives (the app's own PATH does not have the user's shell additions).
    private static func executable() -> String? {
        let home = NSHomeDirectory()
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `claude` in an empty temporary folder, stopped after `timeout`: its answer (the `result` line of its
    /// stream-json output, `AssistantClaudeStream`), returned as soon as it is there (#248: Claude Code takes about a
    /// second more to exit, which is not waited for). `input` goes in on standard input. The folder is always the same
    /// one (no tool can write to it): Claude Code still makes an (empty) project folder under `~/.claude/projects` for
    /// its working directory, and so makes only one. `progress` hears when the process started, its first output and
    /// first text came and the answer was there; `sentence` each sentence of the answer, made fit to speak, as it is
    /// written (`AssistantSpokenStream`: only for calls without tools, else none before the last turn ended). Both
    /// from any thread.
    static func run(arguments: [String], input: String? = nil, timeout: TimeInterval, progress: Progress? = nil,
                    sentence: (@Sendable (String) -> Void)? = nil) async throws -> String {
        guard let executable = executable() else { throw Failure.notFound }
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
        progress?(.claudeSpawn, Date())
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        // The user moved on (a new request, barge-in, off): the process is stopped, its answer never used.
        let running = RunningProcess(process)
        let spoken = AssistantSpokenStream(streaming: !arguments.contains("--allowedTools"))
        return try await withTaskCancellationHandler {
            try await wait(for: process, output: output, timeout: timeout, spoken: spoken, progress: progress, sentence: sentence)
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

    private static func wait(for process: Process, output: Pipe, timeout: TimeInterval, spoken: AssistantSpokenStream,
                             progress: Progress?, sentence: (@Sendable (String) -> Void)?) async throws -> String {
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
                    finish(.failure(Failure.timedOut))
                }
            }
            DispatchQueue.global().async {
                var spoken = spoken
                var pending = Data()
                var firstByte = true
                var firstText = true
                // Lines as they come; the answer is taken from its `result` line, then the rest is only drained.
                while true {
                    let chunk = output.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    if firstByte {
                        firstByte = false
                        progress?(.claudeFirstByte, Date())
                    }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                        let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                        pending.removeSubrange(pending.startIndex...newline)
                        for event in AssistantClaudeStream.events(inLine: line) {
                            if case .text = event, firstText {
                                firstText = false
                                progress?(.claudeFirstText, Date())
                            }
                            for text in spoken.take(event) { sentence?(text) }
                            if case .result(let text, let isError) = event {
                                progress?(.claudeDone, Date())
                                let answer = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                finish(isError || answer.isEmpty ? .failure(Failure.failed(0)) : .success(answer))
                            }
                        }
                    }
                }
                process.waitUntilExit()
                // No result line: it failed (or was stopped).
                finish(.failure(Failure.failed(process.terminationStatus)))
            }
        }
    }
}
