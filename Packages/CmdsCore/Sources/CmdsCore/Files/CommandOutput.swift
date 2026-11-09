#if os(macOS)
import Foundation

/// Runs a short command off the main thread and returns its stdout (files pane: `git status`, GitStatusReader;
/// worktrees: `Git`).
///
/// stdout and stderr are read while the command runs (a full pipe would block it), in chunks collected under a lock.
/// After the command exits, the rest of the pipes is read for at most `drainTimeout`: a child that inherited them and
/// keeps them open (a daemon it started) then neither hangs the caller nor a reader thread. Everything the command
/// itself wrote is in the pipes by the time it exits, so the output is complete.
public enum CommandOutput {
    /// What a finished run wrote and how it ended.
    public struct Completion: Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: Data
    }

    /// stdout of a run that exits with status 0 within `timeout` seconds; nil when it cannot start, fails or is too
    /// slow (it is then terminated). stdin and stderr are /dev/null.
    public static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                           timeout: TimeInterval, drainTimeout: TimeInterval = 2) -> Data? {
        guard let completion = complete(executable, arguments, environment: environment, timeout: timeout,
                                        drainTimeout: drainTimeout, captureStderr: false),
              completion.status == 0 else { return nil }
        return completion.stdout
    }

    /// stdout, stderr and the exit status of a run that ends within `timeout` seconds, whatever the status; nil when
    /// it cannot start or is too slow (it is then terminated). stdin is /dev/null; `directory` is its working
    /// directory (default: inherited).
    public static func complete(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                                directory: String? = nil, timeout: TimeInterval, drainTimeout: TimeInterval = 2,
                                captureStderr: Bool = true) -> Completion? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true) }
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        let stdout = Stream()
        process.standardOutput = stdout.pipe
        let stderr = captureStderr ? Stream() : nil
        process.standardError = stderr?.pipe ?? FileHandle.nullDevice
        defer {
            stdout.stop()
            stderr?.stop()
        }
        do {
            try process.run()
        } catch {
            return nil
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 1)
            return nil
        }
        let deadline = DispatchTime.now() + drainTimeout
        _ = stdout.endOfFile.wait(timeout: deadline)
        _ = stderr?.endOfFile.wait(timeout: deadline)
        return Completion(status: process.terminationStatus, stdout: stdout.data, stderr: stderr?.data ?? Data())
    }

    /// One output pipe, read in chunks on the file handle's queue and collected for the caller.
    private final class Stream: @unchecked Sendable {
        let pipe = Pipe()
        let endOfFile = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var collected = Data()

        init() {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    self?.endOfFile.signal()
                } else {
                    self?.append(chunk)
                }
            }
        }

        /// No explicit close: a handler may still be running; the handle closes when the last reference goes.
        func stop() { pipe.fileHandleForReading.readabilityHandler = nil }

        private func append(_ chunk: Data) {
            lock.lock()
            collected.append(chunk)
            lock.unlock()
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return collected
        }
    }
}
#endif
