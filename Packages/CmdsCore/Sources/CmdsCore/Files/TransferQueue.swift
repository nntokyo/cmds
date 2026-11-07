import Foundation

/// The transfer queue (docs/guide/files.md "Transfers"): jobs run in the order they were added, at most
/// `maxRunning` at a time and one at a time per destination folder, each on its own thread. Finished jobs stay listed
/// (with their log) until cleared.
public final class TransferQueue: @unchecked Sendable {
    /// Jobs running at the same time.
    public var maxRunning = 2
    /// Snapshots changed (on `callbackQueue`, at most every `changeInterval`).
    public var onChange: (() -> Void)?
    public let callbackQueue: DispatchQueue
    public static let changeInterval: TimeInterval = 0.1

    private let lock = NSLock()
    private var jobs: [TransferJob] = []
    private var running = Set<Int>()
    private var nextID = 1
    private var changePending = false

    public init(callbackQueue: DispatchQueue = .main) {
        self.callbackQueue = callbackQueue
    }

    public var snapshots: [TransferJob.Snapshot] {
        lock.lock()
        let list = jobs
        lock.unlock()
        return list.map(\.snapshot)
    }

    public func job(id: Int) -> TransferJob? {
        lock.lock()
        defer { lock.unlock() }
        return jobs.first { $0.id == id }
    }

    /// A new job id (jobs are numbered in the order they are made).
    public func makeID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        return id
    }

    /// Adds a job (made with `makeID()`) and starts it when there is room.
    public func add(_ job: TransferJob) {
        let previous = job.onChange
        job.onChange = { [weak self] in
            previous?()
            self?.changed()
        }
        lock.lock()
        jobs.append(job)
        lock.unlock()
        changed()
        schedule()
    }

    public func retry(id: Int) -> Bool {
        guard let job = job(id: id), job.prepareRetry() else { return false }
        changed()
        schedule()
        return true
    }

    /// Removes finished jobs from the list.
    public func clearFinished() {
        lock.lock()
        jobs.removeAll { $0.currentState.isFinished && !running.contains($0.id) }
        lock.unlock()
        changed()
    }

    /// Cancels every job (app quit, tests).
    public func cancelAll() {
        lock.lock()
        let list = jobs
        lock.unlock()
        list.forEach { $0.cancel() }
    }

    private func schedule() {
        var toStart: [TransferJob] = []
        lock.lock()
        var busyFolders = Set(jobs.filter { running.contains($0.id) }.map(\.destination))
        for job in jobs where running.count + toStart.count < maxRunning {
            guard job.currentState == .queued || (job.currentState == .paused && job.snapshot.started == nil),
                  !running.contains(job.id), !busyFolders.contains(job.destination) else { continue }
            busyFolders.insert(job.destination)
            toStart.append(job)
        }
        for job in toStart { running.insert(job.id) }
        lock.unlock()
        for job in toStart {
            let thread = Thread { [weak self] in
                job.run()
                self?.finished(job)
            }
            thread.name = "cmds.transfer-\(job.id)"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    private func finished(_ job: TransferJob) {
        lock.lock()
        running.remove(job.id)
        lock.unlock()
        changed()
        schedule()
    }

    private func changed() {
        lock.lock()
        if changePending {
            lock.unlock()
            return
        }
        changePending = true
        lock.unlock()
        callbackQueue.asyncAfter(deadline: .now() + Self.changeInterval) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.changePending = false
            self.lock.unlock()
            self.onChange?()
        }
    }
}

/// A transfer as the socket API reports it (`transfer.list`, `cmds transfers`). Locations are `HOST:PATH` for SSH
/// hosts, paths for this Mac.
public struct TransferInfo: Codable, Equatable, Sendable {
    public struct Failure: Codable, Equatable, Sendable {
        public var path: String
        public var message: String
    }

    public var id: Int
    public var mode: TransferJob.Mode
    public var state: TransferJob.State
    public var sources: [String]
    public var destination: String
    public var itemsDone: Int
    public var itemsTotal: Int
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public var current: String?
    /// Why the job stopped as a whole (a connection), or nil.
    public var error: String?
    /// Waiting for an answer about this name (a name conflict).
    public var asking: String?
    /// Log counts: copied (also replaced, kept both, completed), moved, skipped.
    public var copied: Int
    public var moved: Int
    public var skipped: Int
    /// Failed items in the log (all of them; `failures` lists the first ones). Nil from an app that did not send it.
    public var failed: Int?
    /// Sync: extra items moved to the Trash (nil for other modes and from older apps).
    public var trashed: Int?
    /// Sync: `leftToRight`, `rightToLeft` or `both` (`sources[0]` is the left folder, `destination` the right one).
    public var direction: FolderSync.Direction?
    /// Failed items (at most `failuresListed`).
    public var failures: [Failure]

    public static let failuresListed = 50

    public init(_ job: TransferJob.Snapshot) {
        id = job.id
        mode = job.mode
        state = job.state
        sources = job.sources.map(\.description)
        destination = job.destination.description
        itemsDone = job.progress.itemsDone
        itemsTotal = job.progress.itemsTotal
        bytesDone = job.progress.bytesDone
        bytesTotal = job.progress.bytesTotal
        current = job.progress.current
        error = job.error?.description
        asking = job.asking
        let counts = job.counts
        copied = counts.copied
        moved = counts.moved
        skipped = counts.skipped
        failed = counts.failed
        trashed = job.mode == .sync ? counts.trashed : nil
        direction = job.syncDirection
        failures = Array(job.log.lazy.compactMap { entry -> Failure? in
            switch entry.outcome {
            case .failed(let reason), .originalKept(let reason):
                return Failure(path: entry.path, message: reason.description)
            default: return nil
            }
        }.prefix(Self.failuresListed))
    }
}
