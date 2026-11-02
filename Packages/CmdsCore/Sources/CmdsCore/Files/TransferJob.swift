import Foundation

/// One copy or move in the transfer queue (docs/guide/files.md "Transfers"): top-level items from one tree into a
/// folder of another (or the same) tree, this Mac or a server. Runs on its own thread; every file operation goes
/// through `FileTree`, so the rules are tested without a network.
///
/// Rules:
/// - A file is written to a temporary `.cmds-part-…` name next to its target and renamed into place when complete
///   (rename never overwrites); cancelling or a failure removes only that temporary file.
/// - A name that is taken follows the conflict policy, or asks (`onConflict`): skip, replace (the existing item goes
///   to the Trash of its tree first; refused when that fails), keep both (`FileNames.keepBoth`), or stop.
/// - A move within one tree is a rename; otherwise the item is copied and the original then goes to the Trash of its
///   tree (on a server: `RemoteTrash`). If that fails, the copy stays and the log says so.
/// - Pause holds at the next chunk; Cancel stops there, and a folder the interrupted item created goes to the Trash.
/// - Retry runs the items that are not done; a folder the job created before is filled in (files already there with
///   the same size are kept).
public final class TransferJob: @unchecked Sendable {
    public enum Mode: String, Codable, Sendable { case copy, move }

    public enum State: String, Codable, Sendable {
        case queued, running, paused, waiting, done, failed, cancelled

        public var isFinished: Bool { self == .done || self == .failed || self == .cancelled }
    }

    public enum ConflictPolicy: String, Codable, Sendable, CaseIterable { case ask, skip, replace, keepBoth }

    public typealias Resolution = FileOperation.Resolution

    public enum Outcome: Equatable, Sendable {
        case copied
        case moved
        case skipped
        /// The existing item went to the Trash first.
        case replaced
        /// Written as another name.
        case keptBoth(String)
        /// Copied into a folder this job had created before (retry).
        case merged
        /// Copied, but the original could not go to the Trash (it is still there).
        case originalKept(String)
        /// A special file (device, socket, FIFO) is not copied.
        case notCopied
        case failed(String)

        public var isFailure: Bool {
            switch self {
            case .failed, .originalKept: return true
            default: return false
            }
        }
    }

    public struct LogEntry: Equatable, Sendable {
        /// Relative to the source's folder (`photos/a.jpg`).
        public var path: String
        public var outcome: Outcome
        public var date: Date
    }

    public struct Progress: Equatable, Sendable {
        public var itemsDone = 0
        public var itemsTotal = 0
        public var bytesDone: Int64 = 0
        public var bytesTotal: Int64 = 0
        /// The file being written (relative path), or nil.
        public var current: String?
        /// Still counting what there is to transfer.
        public var counting = false
    }

    /// The state of the job at one moment (for the UI, API and tests).
    public struct Snapshot: Equatable, Sendable {
        public var id: Int
        public var mode: Mode
        public var sources: [FileLocation]
        public var destination: FileLocation
        public var state: State
        public var progress: Progress
        public var log: [LogEntry]
        /// Why the job failed as a whole (a connection), or nil.
        public var error: String?
        public var started: Date?
        public var finished: Date?
        /// Waiting for an answer to a conflict about this name.
        public var asking: String?
    }

    public let id: Int
    public let mode: Mode
    public let sources: [FileLocation]
    public let destination: FileLocation
    public let policy: ConflictPolicy

    /// The tree a location is on (connects to a server when needed; called on the job's thread).
    public var tree: (FileLocation) throws -> FileTree = { _ in LocalFileTree() }
    /// Something changed (called on the job's thread; the queue throttles and hops to its callback queue).
    public var onChange: (@Sendable () -> Void)?
    /// A name is taken and the policy is `ask`: call `reply` once (any thread) with the choice and whether it applies
    /// to every further conflict of this job. Called on the job's thread.
    public var onConflict: ((_ name: String, _ isFolder: Bool, _ reply: @escaping @Sendable (Resolution, Bool) -> Void) -> Void)?

    /// Log entries kept per job (the oldest are dropped beyond).
    public static let logLimit = 2000

    private let lock = NSLock()
    private let wake = NSCondition()
    private var state: State = .queued
    private var progress = Progress()
    private var log: [LogEntry] = []
    private var error: String?
    private var started: Date?
    private var finished: Date?
    private var asking: String?
    private var pauseRequested = false
    private var cancelRequested = false
    /// Top-level items finished (done or skipped; not to be repeated by Retry).
    private var completed = Set<Int>()
    /// Folders this job created (by path in the destination tree), so Retry can fill them in.
    private var ownFolders = Set<String>()
    private var applyToAll: Resolution?
    /// Failures logged so far (all runs; the log itself is capped).
    private var failureTotal = 0

    public init(id: Int, mode: Mode, sources: [FileLocation], destination: FileLocation, policy: ConflictPolicy = .ask) {
        self.id = id
        self.mode = mode
        self.sources = sources
        self.destination = destination
        self.policy = policy
    }

    public var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(id: id, mode: mode, sources: sources, destination: destination, state: state, progress: progress,
                        log: log, error: error, started: started, finished: finished, asking: asking)
    }

    public var currentState: State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    // MARK: - Control (any thread)

    public func pause() {
        update {
            guard $0.state == .running || $0.state == .queued || $0.state == .waiting else { return }
            $0.pauseRequested = true
            if $0.state == .running { $0.state = .paused }
        }
        signal()
    }

    public func resume() {
        update {
            $0.pauseRequested = false
            if $0.state == .paused { $0.state = .running }
        }
        signal()
    }

    public func cancel() {
        update {
            $0.cancelRequested = true
            if $0.state == .queued || ($0.state == .paused && $0.started == nil) {
                $0.state = .cancelled
                $0.finished = Date()
            }
        }
        signal()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelRequested
    }

    /// Makes a failed or cancelled job run again (the queue starts it): items already done are not repeated.
    public func prepareRetry() -> Bool {
        var ok = false
        update {
            guard $0.state == .failed || $0.state == .cancelled else { return }
            ok = true
            $0.state = .queued
            $0.cancelRequested = false
            $0.pauseRequested = false
            $0.error = nil
            $0.finished = nil
            $0.applyToAll = nil
        }
        return ok
    }

    private func update(_ change: (TransferJob) -> Void) {
        lock.lock()
        change(self)
        lock.unlock()
        onChange?()
    }

    private func signal() {
        wake.lock()
        wake.broadcast()
        wake.unlock()
    }

    // MARK: - Run (the job's thread)

    private struct Cancelled: Error {}

    /// Runs until done, failed or cancelled. The queue calls it on a thread of its own.
    public func run() {
        var startState: State = .running
        update {
            if $0.cancelRequested {
                startState = .cancelled
                return
            }
            $0.state = $0.pauseRequested ? .paused : .running
            $0.started = $0.started ?? Date()
        }
        guard startState != .cancelled else { return finish(.cancelled) }
        let sourceTree: FileTree
        let destinationTree: FileTree
        do {
            sourceTree = try tree(sources.first ?? destination)
            destinationTree = try tree(destination)
        } catch {
            return finish(.failed, error: "\(error)")
        }
        let failuresBefore = failureCount()
        do {
            try checkpoint()
            try measure(sourceTree)
            for (index, source) in sources.enumerated() where !isCompleted(index) {
                try checkpoint()
                let finishedItem = try transferTopLevel(source, from: sourceTree, to: destinationTree)
                if finishedItem { markCompleted(index) }
            }
            finish(failureCount() > failuresBefore ? .failed : .done)
        } catch is Cancelled {
            finish(.cancelled)
        } catch is StopRequested {
            finish(.cancelled)
        } catch {
            finish(.failed, error: "\(error)")
        }
    }

    private struct StopRequested: Error {}

    private func finish(_ final: State, error message: String? = nil) {
        update {
            $0.state = final
            $0.finished = Date()
            $0.progress.current = nil
            $0.progress.counting = false
            $0.asking = nil
            if let message { $0.error = message }
        }
    }

    private func isCompleted(_ index: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed.contains(index)
    }

    private func markCompleted(_ index: Int) {
        lock.lock()
        completed.insert(index)
        lock.unlock()
    }

    /// Waits while paused; throws when cancelled.
    private func checkpoint() throws {
        wake.lock()
        defer { wake.unlock() }
        while true {
            lock.lock()
            let cancelled = cancelRequested
            let paused = pauseRequested
            lock.unlock()
            if cancelled { throw Cancelled() }
            if !paused {
                setState(.running)
                return
            }
            setState(.paused)
            wake.wait(until: Date().addingTimeInterval(1))
        }
    }

    private func setState(_ new: State) {
        lock.lock()
        let changed = state != new
        state = new
        lock.unlock()
        if changed { onChange?() }
    }

    private func record(_ path: String, _ outcome: Outcome) {
        update {
            $0.log.append(LogEntry(path: path, outcome: outcome, date: Date()))
            if outcome.isFailure { $0.failureTotal += 1 }
            if $0.log.count > Self.logLimit { $0.log.removeFirst($0.log.count - Self.logLimit) }
        }
    }

    /// Items and bytes to transfer (renames count as items without bytes).
    private func measure(_ tree: FileTree) throws {
        update { $0.progress.counting = true }
        var items = 0
        var bytes: Int64 = 0
        for (index, source) in sources.enumerated() where !isCompleted(index) {
            items += 1
            if mode == .move, source.isSameTree(as: destination) { continue }
            bytes += try size(of: source.path, in: tree)
        }
        update {
            $0.progress.counting = false
            $0.progress.itemsTotal = items + $0.progress.itemsDone
            $0.progress.bytesTotal = bytes + $0.progress.bytesDone
        }
    }

    private func size(of path: String, in tree: FileTree) throws -> Int64 {
        try checkpoint()
        guard let item = try tree.item(at: path) else { return 0 }
        switch item.kind {
        case .file: return item.size
        case .folder:
            var total: Int64 = 0
            for child in (try? tree.list(path)) ?? [] {
                total += try size(of: join(path, child.name, tree: tree), in: tree)
            }
            return total
        default: return 0
        }
    }

    private func join(_ folder: String, _ name: String, tree: FileTree) -> String {
        tree is SFTPFileTree ? RemotePath.join(folder, name) : (folder as NSString).appendingPathComponent(name)
    }

    private func parentPath(_ path: String, tree: FileTree) -> String {
        tree is SFTPFileTree ? RemotePath.parent(path) : (path as NSString).deletingLastPathComponent
    }

    private func isSameOrInside(_ path: String, _ folder: String, tree: FileTree) -> Bool {
        tree is SFTPFileTree ? RemotePath.isSameOrInside(path, folder) : FileNames.isSameOrInside(path, folder)
    }

    /// One top-level item; returns true when it needs no retry (done, skipped, or failed for good).
    private func transferTopLevel(_ source: FileLocation, from sourceTree: FileTree, to destinationTree: FileTree) throws -> Bool {
        let name = source.name
        defer { update { $0.progress.itemsDone += 1 } }
        guard let item = try sourceTree.item(at: source.path) else {
            record(name, .failed("No such file or folder"))
            return false
        }
        if item.kind == .other {
            record(name, .notCopied)
            return true
        }
        let sameTree = source.isSameTree(as: destination)
        if sameTree, isSameOrInside(destination.path, source.path, tree: destinationTree) {
            record(name, .failed("A folder cannot be copied or moved into itself."))
            return true
        }
        let destinationFolder = destination.path
        var target = join(destinationFolder, name, tree: destinationTree)
        var merging = false
        var outcome: Outcome = mode == .move ? .moved : .copied
        if sameTree && parentPath(source.path, tree: sourceTree) == destinationFolder {
            guard mode == .copy else {
                record(name, .skipped)
                return true
            }
            target = join(destinationFolder, keepBothName(name, isFolder: item.kind == .folder, in: destinationFolder,
                                                          tree: destinationTree), tree: destinationTree)
        } else if let existing = try destinationTree.item(at: target) {
            if existing.kind == .folder, item.kind == .folder, ownFolder(target) {
                merging = true
            } else {
                switch try resolve(name: name, isFolder: existing.kind == .folder) {
                case .stop:
                    throw StopRequested()
                case .skip:
                    record(name, .skipped)
                    addBytesDone(sameTree && mode == .move ? 0 : try size(of: source.path, in: sourceTree))
                    return true
                case .keepBoth:
                    let newName = keepBothName(name, isFolder: item.kind == .folder, in: destinationFolder, tree: destinationTree)
                    target = join(destinationFolder, newName, tree: destinationTree)
                    outcome = .keptBoth(newName)
                case .replace:
                    if sameTree, isSameOrInside(source.path, target, tree: sourceTree) {
                        record(name, .failed("The item to replace contains the item being moved."))
                        return true
                    }
                    do {
                        try destinationTree.trash(target)
                    } catch {
                        record(name, .failed("The existing item could not be moved to the Trash: \(error)"))
                        return true
                    }
                    outcome = .replaced
                }
            }
        }
        if merging { outcome = .merged }
        if mode == .move, sameTree {
            do {
                try sourceTree.rename(source.path, to: target)
                record(name, outcome)
                return true
            } catch {
                // Another file system on the same host: copy and trash instead.
            }
        }
        let topCreatedFolder = item.kind == .folder && !merging
        do {
            let failuresBefore = failureCount()
            try copy(item, from: source.path, in: sourceTree, to: target, in: destinationTree, relative: name,
                     merging: merging, isTopLevel: true)
            guard failureCount() == failuresBefore else { return false }
            if mode == .move {
                do {
                    try sourceTree.trash(source.path)
                } catch {
                    record(name, .originalKept("\(error)"))
                    return true
                }
            }
            record(name, outcome)
            return true
        } catch is Cancelled {
            if topCreatedFolder, ownFolder(target) { try? destinationTree.trash(target) }
            throw Cancelled()
        }
    }

    private func failureCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return failureTotal
    }

    private func ownFolder(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ownFolders.contains(path)
    }

    private func addBytesDone(_ bytes: Int64) {
        update { $0.progress.bytesDone += bytes }
    }

    private func keepBothName(_ name: String, isFolder: Bool, in folder: String, tree: FileTree) -> String {
        FileNames.keepBoth(name, isFolder: isFolder) { tree.exists(join(folder, $0, tree: tree)) }
    }

    private func resolve(name: String, isFolder: Bool) throws -> Resolution {
        if let applyToAll { return applyToAll }
        switch policy {
        case .skip: return .skip
        case .replace: return .replace
        case .keepBoth: return .keepBoth
        case .ask: break
        }
        guard let onConflict else { return .skip }
        let semaphore = DispatchSemaphore(value: 0)
        let answer = Answer()
        update {
            $0.asking = name
            $0.state = .waiting
        }
        onConflict(name, isFolder) { resolution, all in
            answer.set(resolution, all)
            semaphore.signal()
        }
        semaphore.wait()
        update { $0.asking = nil }
        try checkpoint()
        let (resolution, all) = answer.get()
        if all, resolution != .stop { applyToAll = resolution }
        return resolution
    }

    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (Resolution, Bool) = (.skip, false)
        func set(_ resolution: Resolution, _ all: Bool) { lock.lock(); value = (resolution, all); lock.unlock() }
        func get() -> (Resolution, Bool) { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Copies one item (recursively) to `target`, which does not exist yet (or is a folder this job created, when
    /// `merging`). Failures inside are logged; throws only to stop the job (cancel, connection gone).
    private func copy(_ item: FileItem, from source: String, in sourceTree: FileTree, to target: String,
                      in destinationTree: FileTree, relative: String, merging: Bool, isTopLevel: Bool = false) throws {
        try checkpoint()
        switch item.kind {
        case .file:
            do {
                try copyFile(item, from: source, in: sourceTree, to: target, in: destinationTree, relative: relative)
                if !isTopLevel { record(relative, .copied) }
            } catch is Cancelled {
                throw Cancelled()
            } catch let error as SFTPError {
                if case .disconnected = error { throw error }
                record(relative, .failed(error.description))
            } catch {
                record(relative, .failed("\(error)"))
            }
        case .folder:
            if !merging {
                do {
                    try destinationTree.makeFolder(target, permissions: item.permissions.map { $0 | 0o700 })
                    lock.lock()
                    ownFolders.insert(target)
                    lock.unlock()
                } catch let error as SFTPError {
                    if case .disconnected = error { throw error }
                    record(relative, .failed(error.description))
                    return
                } catch {
                    record(relative, .failed("\(error)"))
                    return
                }
            }
            let children: [FileItem]
            do {
                children = try sourceTree.list(source)
            } catch let error as SFTPError {
                if case .disconnected = error { throw error }
                record(relative, .failed(error.description))
                return
            } catch {
                record(relative, .failed("\(error)"))
                return
            }
            for child in children.sorted(by: { $0.name < $1.name }) {
                let childTarget = join(target, child.name, tree: destinationTree)
                var childMerging = false
                // Retry into a folder this job made: what is there already stays (files of the same size count as done).
                if merging, let existing = try destinationTree.item(at: childTarget) {
                    if child.kind == .folder, existing.kind == .folder {
                        childMerging = true
                    } else {
                        if child.kind == .file, existing.kind == .file, existing.size == child.size {
                            addBytesDone(child.size)
                        } else {
                            record(relative + "/" + child.name, .skipped)
                        }
                        continue
                    }
                }
                try copy(child, from: join(source, child.name, tree: sourceTree), in: sourceTree, to: childTarget,
                         in: destinationTree, relative: relative + "/" + child.name, merging: childMerging)
            }
            destinationTree.setAttributes(target, modified: item.modified, permissions: nil)
        case .symlink:
            do {
                let linkTarget = try sourceTree.readLink(source)
                try destinationTree.makeLink(target, target: linkTarget)
                if !isTopLevel { record(relative, .copied) }
            } catch let error as SFTPError {
                if case .disconnected = error { throw error }
                record(relative, .failed(error.description))
            } catch {
                record(relative, .failed("\(error)"))
            }
        case .other:
            record(relative, .notCopied)
        }
    }

    /// Streams a file into a temporary name next to `target`, then renames it into place.
    private func copyFile(_ item: FileItem, from source: String, in sourceTree: FileTree, to target: String,
                          in destinationTree: FileTree, relative: String) throws {
        let folder = parentPath(target, tree: destinationTree)
        let finalName = target.split(separator: "/").last.map(String.init) ?? relative
        let part = join(folder, TransferNames.part(for: finalName), tree: destinationTree)
        update { $0.progress.current = relative }
        let reader = try sourceTree.openForReading(source)
        defer { reader.close() }
        let writer = try destinationTree.createFile(part, permissions: (item.permissions ?? 0o644) | 0o600)
        var written: Int64 = 0
        do {
            while true {
                try checkpoint()
                let chunk = try reader.read()
                if chunk.isEmpty { break }
                try writer.write(chunk)
                written += Int64(chunk.count)
                addBytesDone(Int64(chunk.count))
            }
            try writer.finish()
        } catch {
            writer.abandon()
            try? destinationTree.removePart(part)
            // Bytes of a file that did not arrive do not count.
            addBytesDone(-written)
            if !(error is Cancelled) { addBytesDone(item.size) }
            throw error
        }
        destinationTree.setAttributes(part, modified: item.modified, permissions: item.permissions)
        do {
            try destinationTree.rename(part, to: target)
        } catch {
            try? destinationTree.removePart(part)
            throw FileTreeError("“\(finalName)” appeared in the destination during the copy; it was left as it is (\(error))")
        }
    }
}
