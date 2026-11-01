#if os(macOS)
import Foundation

/// Runs a short command off the main thread and returns its stdout (files pane: `git status`, GitStatusReader).
///
/// stdout is read while the command runs (a full pipe would block it), in chunks collected under a lock. After the
/// command exits, the rest of the pipe is read for at most `drainTimeout`: a child that inherited stdout and keeps it
/// open (a daemon it started) then neither hangs the caller nor a reader thread. Everything the command itself wrote
/// is in the pipe by the time it exits, so the output is complete.
public enum CommandOutput {
    /// stdout of a run that exits with status 0 within `timeout` seconds; nil when it cannot start, fails or is too
    /// slow (it is then terminated). stdin and stderr are /dev/null.
    public static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                           timeout: TimeInterval, drainTimeout: TimeInterval = 2) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        let buffer = Buffer()
        let endOfFile = DispatchSemaphore(value: 0)
        let reading = output.fileHandleForReading
        reading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                endOfFile.signal()
            } else {
                buffer.append(chunk)
            }
        }
        // No explicit close: a handler may still be running; the handle closes when the last reference goes.
        defer { reading.readabilityHandler = nil }
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
        _ = endOfFile.wait(timeout: .now() + drainTimeout)
        return process.terminationStatus == 0 ? buffer.data : nil
    }

    /// Chunks of stdout, appended on the file handle's queue and read by the caller.
    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var collected = Data()

        func append(_ chunk: Data) {
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
