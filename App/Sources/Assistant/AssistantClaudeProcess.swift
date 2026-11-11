import CmdsCore
import Foundation

/// Runs `claude -p` for the assistant (#243): the arguments come from `AssistantClaude` (isolated from the user's Claude
/// Code setup, tools limited per call), in an empty temporary folder, without cmds' pane variables, stopped after a
/// timeout or when the task asking for it is cancelled. Only its standard output is read.
enum AssistantClaudeProcess {
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

    /// Runs `claude` in an empty temporary folder, stopped after `timeout`: its standard output, trimmed. `input` goes
    /// in on standard input. The folder is always the same one (no tool can write to it): Claude Code still makes an
    /// (empty) project folder under `~/.claude/projects` for its working directory, and so makes only one.
    static func run(arguments: [String], input: String? = nil, timeout: TimeInterval) async throws -> String {
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
                    finish(.failure(Failure.timedOut))
                }
            }
            DispatchQueue.global().async {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0, !text.isEmpty {
                    finish(.success(text))
                } else {
                    finish(.failure(Failure.failed(process.terminationStatus)))
                }
            }
        }
    }
}
