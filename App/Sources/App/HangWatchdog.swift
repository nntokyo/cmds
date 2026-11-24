import Foundation
import CmdsCore
import os

private let hangLog = Logger(subsystem: "tokyo.n-n.cmds", category: "hang")

/// Watches the main thread from a background queue (`HangWatchdogPolicy`). A beat is sent to the main queue every
/// second; when it has not run for `recordAfter`, `/usr/bin/sample` records every thread of cmds once for that hang
/// into `<support dir>/hangs`, and `hangs.log` notes when it started and, when the main thread answers again, how long
/// it lasted. Meanwhile `system.ping` is answered from the socket's thread as busy (APIServer), so a script or an agent
/// can tell a hung cmds from one that is not running.
final class HangWatchdog: @unchecked Sendable {
    static let shared = HangWatchdog()

    private let queue = DispatchQueue(label: "tokyo.n-n.cmds.hang-watchdog", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var directory: URL?
    /// A beat posted to the main queue that has not run yet, since then.
    private var pendingSince: Date?
    private var recordedThisHang = false
    private var lastRecordAt: Date?
    private var lastReport: String?

    /// Starts watching; samples go to `supportDirectory/hangs`.
    func start(supportDirectory: URL) {
        lock.withLock { directory = supportDirectory.appendingPathComponent(HangWatchdogPolicy.directoryName, isDirectory: true) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + HangWatchdogPolicy.checkInterval, repeating: HangWatchdogPolicy.checkInterval,
                       leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.check() }
        self.timer = timer
        timer.resume()
    }

    /// How long the main thread has not answered (0 while it does).
    var mainBlockedFor: TimeInterval {
        lock.withLock { pendingSince.map { Date().timeIntervalSince($0) } ?? 0 }
    }

    /// The latest sample's path (nil before the first hang).
    var latestReport: String? { lock.withLock { lastReport } }

    private func check() {
        let now = Date()
        let (blocked, record): (TimeInterval?, Bool) = lock.withLock {
            guard let since = pendingSince else {
                pendingSince = now
                return (nil, false)
            }
            let blocked = now.timeIntervalSince(since)
            let record = HangWatchdogPolicy.shouldRecord(blockedFor: blocked, recordedThisHang: recordedThisHang,
                                                         lastRecordAt: lastRecordAt, now: now)
            if record {
                recordedThisHang = true
                lastRecordAt = now
            }
            return (blocked, record)
        }
        if blocked == nil {
            // A new beat: when it runs, the main thread is free.
            DispatchQueue.main.async { [weak self] in self?.beat() }
        } else if record, let blocked {
            recordSample(blockedFor: blocked, at: now)
        }
    }

    private func beat() {
        let ended: (since: Date, recorded: Bool)? = lock.withLock {
            defer {
                pendingSince = nil
                recordedThisHang = false
            }
            guard let since = pendingSince, recordedThisHang else { return nil }
            return (since, true)
        }
        guard let ended else { return }
        let duration = Date().timeIntervalSince(ended.since)
        hangLog.error("the main thread answers again after \(Int(duration)) s")
        queue.async { [weak self] in self?.appendLog(HangWatchdogPolicy.logLine(startedAt: ended.since, duration: duration, file: nil)) }
    }

    private func recordSample(blockedFor: TimeInterval, at now: Date) {
        guard let directory = lock.withLock({ directory }) else { return }
        let file = directory.appendingPathComponent(HangWatchdogPolicy.fileName(at: now))
        hangLog.error("the main thread has not answered for \(Int(blockedFor)) s; sampling to \(file.path, privacy: .public)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            hangLog.error("cannot create \(directory.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        let started = now.addingTimeInterval(-blockedFor)
        appendLog(HangWatchdogPolicy.logLine(startedAt: started, duration: nil, file: file.lastPathComponent))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), String(HangWatchdogPolicy.sampleSeconds),
                             "-file", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()  // on the watchdog's queue, never the main thread
        } catch {
            hangLog.error("sample did not start: \(String(describing: error), privacy: .public)")
            return
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        lock.withLock { lastReport = file.path }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for old in HangWatchdogPolicy.filesToDelete(names) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(old))
        }
    }

    private func appendLog(_ line: String) {
        guard let directory = lock.withLock({ directory }) else { return }
        let url = directory.appendingPathComponent(HangWatchdogPolicy.logName)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: url.path, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600])
        }
    }
}
