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
/// - Save (`.save`, editing a server's file): the edited copy on this Mac goes over the file it came from. When the
///   server's file is not as it was last read or written (`SaveRequest.base`), the conflict is asked: Replace keeps
///   the copy (uploads it), Skip keeps the server's file (downloads it into the copy), Keep Both uploads the copy
///   under a numbered name, Stop uploads nothing. The upload is written to a part file with the server file's
///   permissions and renamed over it in one step (`renameReplacing`); on a server without that, its file goes to its
///   Trash first, as Replace does.
/// - Sync (`.sync`, docs/guide/files.md "Comparing and syncing folders"): the actions of a `FolderSync` plan between
///   two folders, each on its own: before an item is changed, the side it changes must still look as the comparison
///   saw it (else it is left alone and logged as changed). A file replacing a file is written to a part file first;
///   the old file then goes to the Trash of its side and the part file is renamed into place. Anything else that is
///   replaced goes to the Trash first. Extra items go to the Trash; nothing is deleted.
public final class TransferJob: @unchecked Sendable {
    public enum Mode: String, Codable, Sendable {
        case copy, move
        /// Upload an edited copy over the server's file it came from.
        case save
        /// Sync two folders (`FolderSync`).
        case sync
    }

    /// `.sync`: the plan's actions between the folders `left` and `right` (the job's source and destination).
    public struct SyncRequest: Equatable, Sendable {
        public var left: FileLocation
        public var right: FileLocation
        public var direction: FolderSync.Direction
        public var actions: [FolderSync.Action]

        public init(left: FileLocation, right: FileLocation, direction: FolderSync.Direction,
                    actions: [FolderSync.Action]) {
            self.left = left
            self.right = right
            self.direction = direction
            self.actions = actions
        }
    }

    /// `.save`: the edited copy (the job's one source) goes over `name` in the destination folder, whose server file
    /// was `base` when it was last downloaded or uploaded.
    public struct SaveRequest: Equatable, Sendable {
        public var name: String
        public var base: RemoteFileVersion

        public init(name: String, base: RemoteFileVersion) {
            self.name = name
            self.base = base
        }
    }

    /// What a save left: the server file that now holds the content (`name` in the destination folder; another one
    /// after Keep Both), its version, and the hash of that content (the upload, or the server's file downloaded into
    /// the copy after Skip).
    public struct SaveResult: Equatable, Sendable {
        public var name: String
        public var version: RemoteFileVersion
        public var contentHash: String
        /// The server's file was downloaded into the copy (Skip: keep theirs).
        public var keptTheirs: Bool
    }

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
        case originalKept(TransferFailure)
        /// A special file (device, socket, FIFO) is not copied.
        case notCopied
        /// Save: uploaded over the server's file.
        case saved
        /// Save: the server's file had changed and was kept; it was downloaded into the edited copy.
        case keptTheirs
        /// Sync: an extra item went to the Trash.
        case trashed
        case failed(TransferFailure)

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
        /// Sync: the side the item was written to or trashed on.
        public var side: FolderSync.Side?

        public init(path: String, outcome: Outcome, date: Date, side: FolderSync.Side? = nil) {
            self.path = path
            self.outcome = outcome
            self.date = date
            self.side = side
        }
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
        public var error: TransferFailure?
        public var started: Date?
        public var finished: Date?
        /// Waiting for an answer to a conflict about this name.
        public var asking: String?
        /// `.save`: the server file's name it goes over.
        public var saving: String?
        /// `.save`: what the save left (nil until it is done, or when nothing was written).
        public var saved: SaveResult?
        /// `.sync`: its direction (the folders are `sources[0]`, left, and `destination`, right).
        public var syncDirection: FolderSync.Direction?

        /// The log counted (Transfers window, `cmds transfers`).
        public var counts: Counts { Counts(log.map(\.outcome)) }
    }

    /// How many items of a log were copied (also replaced, kept both, completed), moved, skipped (also special files)
    /// or failed (also originals left in place).
    public struct Counts: Equatable, Sendable {
        public var copied = 0
        public var moved = 0
        public var skipped = 0
        public var failed = 0
        /// Sync: extra items moved to the Trash.
        public var trashed = 0

        public init(_ outcomes: [Outcome]) {
            for outcome in outcomes {
                switch outcome {
                case .copied, .replaced, .keptBoth, .merged, .saved: copied += 1
                case .moved: moved += 1
                case .skipped, .notCopied, .keptTheirs: skipped += 1
                case .failed, .originalKept: failed += 1
                case .trashed: trashed += 1
                }
            }
        }
    }

    public let id: Int
    public let mode: Mode
    public let sources: [FileLocation]
    public let destination: FileLocation
    public let policy: ConflictPolicy
    /// `.save` only.
    public let save: SaveRequest?
    /// `.sync` only.
    public let sync: SyncRequest?

    /// The tree a location is on (connects to a server when needed; called on the job's thread).
    public var tree: (FileLocation) throws -> FileTree = { _ in LocalFileTree() }
    /// Something changed (called on the job's thread; the queue throttles and hops to its callback queue).
    public var onChange: (@Sendable () -> Void)?
    /// A name is taken and the policy is `ask`: call `reply` once (any thread) with the choice and whether it applies
    /// to every further conflict of this job. Called on the job's thread.
    public var onConflict: ((_ name: String, _ isFolder: Bool, _ reply: @escaping @Sendable (Resolution, Bool) -> Void) -> Void)?
    /// Records the part files the job is writing (the app's journal in the support folder).
    public var partJournal: TransferPartJournal?

    /// Log entries kept per job (the oldest are dropped beyond).
    public static let logLimit = 2000

    private let lock = NSLock()
    private let wake = NSCondition()
    private var state: State = .queued
    private var progress = Progress()
    private var log: [LogEntry] = []
    private var error: TransferFailure?
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
    private var saved: SaveResult?
    /// Sync actions whose old item already went to the Trash (a retry then expects nothing there).
    private var syncTrashed = Set<Int>()
    /// Sync: the host of the side being written (part files are journaled under it); the job's thread only.
    private var targetHost: String??
    /// Sync: the side the running action changes (its log entries, also those of a folder's contents, name it).
    private var syncSide: FolderSync.Side?

    /// A copy or move (`mode` `.copy` or `.move`).
    public init(id: Int, mode: Mode, sources: [FileLocation], destination: FileLocation, policy: ConflictPolicy = .ask) {
        precondition(mode != .save && mode != .sync, "a save or sync has its own init")
        self.id = id
        self.mode = mode
        self.sources = sources
        self.destination = destination
        self.policy = policy
        save = nil
        sync = nil
    }

    /// A save: the edited copy at `copy` (on this Mac) goes over `request.name` in `folder` (on a server).
    public init(id: Int, saving copy: FileLocation, to folder: FileLocation, _ request: SaveRequest,
                policy: ConflictPolicy = .ask) {
        self.id = id
        mode = .save
        sources = [copy]
        destination = folder
        self.policy = policy
        save = request
        sync = nil
    }

    /// A sync between two folders (`FolderSync.plan`); the left one is the source, the right one the destination.
    public init(id: Int, syncing request: SyncRequest) {
        self.id = id
        mode = .sync
        sources = [request.left]
        destination = request.right
        policy = .skip
        save = nil
        sync = request
    }

    public var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(id: id, mode: mode, sources: sources, destination: destination, state: state, progress: progress,
                        log: log, error: error, started: started, finished: finished, asking: asking, saving: save?.name, saved: saved,
                        syncDirection: sync?.direction)
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

    /// Cancel was requested (seen at a checkpoint).
    private struct Cancelled: Error {}
    /// Stop was the answer to a name conflict.
    private struct StopRequested: Error {}

    /// While paused, how often the job looks again in case a signal was missed.
    private static let pausePollInterval: TimeInterval = 1

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
            return finish(.failed, error: TransferFailure(error))
        }
        let failuresBefore = failureCount()
        do {
            try checkpoint()
            if let save {
                try runSave(save, from: sourceTree, to: destinationTree)
            } else if let sync {
                try runSync(sync, left: sourceTree, right: destinationTree)
            } else {
                try measure(sourceTree)
                for (index, source) in sources.enumerated() where !isCompleted(index) {
                    try checkpoint()
                    let finishedItem = try transferTopLevel(source, from: sourceTree, to: destinationTree)
                    if finishedItem { markCompleted(index) }
                }
            }
            finish(failureCount() > failuresBefore ? .failed : .done)
        } catch is Cancelled, is StopRequested {
            finish(.cancelled)
        } catch {
            finish(.failed, error: TransferFailure(error))
        }
    }

    private func finish(_ final: State, error message: TransferFailure? = nil) {
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
            wake.wait(until: Date().addingTimeInterval(Self.pausePollInterval))
        }
    }

    private func setState(_ new: State) {
        lock.lock()
        let changed = state != new
        state = new
        lock.unlock()
        if changed { onChange?() }
    }

    private func record(_ path: String, _ outcome: Outcome, side: FolderSync.Side? = nil) {
        update {
            $0.log.append(LogEntry(path: path, outcome: outcome, date: Date(), side: side ?? $0.syncSide))
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
                total += try size(of: tree.paths.join(path, child.name), in: tree)
            }
            return total
        default: return 0
        }
    }

    /// Where a top-level item is written, once a name conflict is settled.
    private struct Target {
        var path: String
        var outcome: Outcome
        /// A folder this job created before (Retry fills it in).
        var merging = false
    }

    /// One top-level item; returns true when it needs no retry (done, skipped, or failed for good).
    private func transferTopLevel(_ source: FileLocation, from sourceTree: FileTree, to destinationTree: FileTree) throws -> Bool {
        let name = source.name
        defer { update { $0.progress.itemsDone += 1 } }
        guard let item = try sourceTree.item(at: source.path) else {
            record(name, .failed(.noSuchItem))
            return false
        }
        if item.kind == .other {
            record(name, .notCopied)
            return true
        }
        let sameTree = source.isSameTree(as: destination)
        if sameTree, destinationTree.paths.isSameOrInside(destination.path, source.path) {
            record(name, .failed(.intoItself))
            return true
        }
        guard let target = try self.target(for: item, at: source, from: sourceTree, to: destinationTree) else { return true }
        // Within one tree a move is a rename; when that fails (another file system on the same host), copy and trash.
        if mode == .move, sameTree, (try? sourceTree.rename(source.path, to: target.path)) != nil {
            record(name, target.outcome)
            return true
        }
        let createdFolder = item.kind == .folder && !target.merging
        do {
            let failuresBefore = failureCount()
            try copy(item, from: source.path, in: sourceTree, to: target.path, in: destinationTree, relative: name,
                     merging: target.merging, isTopLevel: true)
            guard failureCount() == failuresBefore else { return false }
            if mode == .move {
                do {
                    try sourceTree.trash(source.path)
                } catch {
                    record(name, .originalKept(TransferFailure(error)))
                    return true
                }
            }
            record(name, target.outcome)
            return true
        } catch is Cancelled {
            if createdFolder, ownFolder(target.path) { try? destinationTree.trash(target.path) }
            throw Cancelled()
        }
    }

    /// The path a top-level item goes to: its name in the destination, another name (a copy into its own folder, Keep
    /// Both), or its name after the existing item went to the Trash (Replace). Nil when it is not written (skipped or
    /// refused; logged).
    private func target(for item: FileItem, at source: FileLocation, from sourceTree: FileTree,
                        to destinationTree: FileTree) throws -> Target? {
        let name = source.name
        let paths = destinationTree.paths
        let folder = destination.path
        let sameTree = source.isSameTree(as: destination)
        let path = paths.join(folder, name)
        let outcome: Outcome = mode == .move ? .moved : .copied
        if sameTree && sourceTree.paths.parent(source.path) == folder {
            guard mode == .copy else {
                record(name, .skipped)
                return nil
            }
            let newName = keepBothName(name, isFolder: item.kind == .folder, in: folder, tree: destinationTree)
            return Target(path: paths.join(folder, newName), outcome: outcome)
        }
        guard let existing = try destinationTree.item(at: path) else { return Target(path: path, outcome: outcome) }
        if existing.kind == .folder, item.kind == .folder, ownFolder(path) {
            return Target(path: path, outcome: .merged, merging: true)
        }
        switch try resolve(name: name, isFolder: existing.kind == .folder) {
        case .stop:
            throw StopRequested()
        case .skip:
            record(name, .skipped)
            addBytesDone(sameTree && mode == .move ? 0 : try size(of: source.path, in: sourceTree))
            return nil
        case .keepBoth:
            let newName = keepBothName(name, isFolder: item.kind == .folder, in: folder, tree: destinationTree)
            return Target(path: paths.join(folder, newName), outcome: .keptBoth(newName))
        case .replace:
            if sameTree, sourceTree.paths.isSameOrInside(source.path, path) {
                record(name, .failed(.replaceContainsSource))
                return nil
            }
            do {
                try destinationTree.trash(path)
            } catch {
                record(name, .failed(.existingNotTrashed(TransferFailure(error))))
                return nil
            }
            return Target(path: path, outcome: .replaced)
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

    private func addOwnFolder(_ path: String) {
        lock.lock()
        ownFolders.insert(path)
        lock.unlock()
    }

    private func addBytesDone(_ bytes: Int64) {
        update { $0.progress.bytesDone += bytes }
    }

    private func keepBothName(_ name: String, isFolder: Bool, in folder: String, tree: FileTree) -> String {
        FileNames.keepBoth(name, isFolder: isFolder) { tree.exists(tree.paths.join(folder, $0)) }
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

    /// Runs one step of copying `relative`: true when it worked. A failure is logged (false), except a lost connection
    /// or a cancel, which stop the job.
    private func attempt(_ relative: String, _ step: () throws -> Void) throws -> Bool {
        do {
            try step()
            return true
        } catch is Cancelled {
            throw Cancelled()
        } catch let error as SFTPError {
            if case .disconnected = error { throw error }
            record(relative, .failed(.sftp(error)))
            return false
        } catch {
            record(relative, .failed(TransferFailure(error)))
            return false
        }
    }

    /// Copies one item (recursively) to `target`, which does not exist yet (or is a folder this job created, when
    /// `merging`). Failures inside are logged; throws only to stop the job (cancel, connection gone).
    private func copy(_ item: FileItem, from source: String, in sourceTree: FileTree, to target: String,
                      in destinationTree: FileTree, relative: String, merging: Bool, isTopLevel: Bool = false) throws {
        try checkpoint()
        switch item.kind {
        case .file:
            let copied = try attempt(relative) {
                try copyFile(item, from: source, in: sourceTree, to: target, in: destinationTree, relative: relative)
            }
            if copied, !isTopLevel { record(relative, .copied) }
        case .folder:
            if !merging {
                let made = try attempt(relative) {
                    try destinationTree.makeFolder(target, permissions: item.permissions.map { $0 | 0o700 })
                    addOwnFolder(target)
                }
                guard made else { return }
            }
            var children: [FileItem] = []
            guard try attempt(relative, { children = try sourceTree.list(source) }) else { return }
            for child in children.sorted(by: { $0.name < $1.name }) {
                try copyChild(child, of: source, in: sourceTree, into: target, in: destinationTree, relative: relative,
                              merging: merging)
            }
            destinationTree.setAttributes(target, modified: item.modified, permissions: nil)
        case .symlink:
            let copied = try attempt(relative) {
                try destinationTree.makeLink(target, target: try sourceTree.readLink(source))
            }
            if copied, !isTopLevel { record(relative, .copied) }
        case .other:
            record(relative, .notCopied)
        }
    }

    /// One item of a folder being copied. Retry into a folder this job made (`merging`): what is there already stays
    /// (files of the same size count as done).
    private func copyChild(_ child: FileItem, of folder: String, in sourceTree: FileTree, into target: String,
                           in destinationTree: FileTree, relative: String, merging: Bool) throws {
        let childTarget = destinationTree.paths.join(target, child.name)
        let childRelative = relative + "/" + child.name
        var childMerging = false
        if merging, let existing = try destinationTree.item(at: childTarget) {
            guard child.kind == .folder, existing.kind == .folder else {
                if child.kind == .file, existing.kind == .file, existing.size == child.size {
                    addBytesDone(child.size)
                } else {
                    record(childRelative, .skipped)
                }
                return
            }
            childMerging = true
        }
        try copy(child, from: sourceTree.paths.join(folder, child.name), in: sourceTree, to: childTarget,
                 in: destinationTree, relative: childRelative, merging: childMerging)
    }

    /// Streams a file into a temporary name next to `target`, then renames it into place. `beforeRename` runs once
    /// the file is complete (sync: the old file goes to the Trash); when it throws, the part file is removed.
    private func copyFile(_ item: FileItem, from source: String, in sourceTree: FileTree, to target: String,
                          in destinationTree: FileTree, relative: String, beforeRename: () throws -> Void = {}) throws {
        let folder = destinationTree.paths.parent(target)
        let finalName = target.split(separator: "/").last.map(String.init) ?? relative
        let part = destinationTree.paths.join(folder, TransferNames.part(for: finalName))
        let partEntry = TransferPartJournal.Entry(host: targetHost ?? destination.host, path: part)
        do {
            _ = try stream(source, from: sourceTree, to: part, in: destinationTree, entry: partEntry,
                           permissions: (item.permissions ?? 0o644) | 0o600, current: relative)
        } catch {
            // A file that did not arrive counts as done (its bytes were taken back), unless the job was cancelled.
            if !(error is Cancelled) { addBytesDone(item.size) }
            throw error
        }
        destinationTree.setAttributes(part, modified: item.modified, permissions: item.permissions)
        do {
            try beforeRename()
        } catch {
            removePart(partEntry, from: destinationTree)
            throw error
        }
        do {
            try destinationTree.rename(part, to: target)
            partJournal?.remove(partEntry)
        } catch {
            removePart(partEntry, from: destinationTree)
            throw TransferFailure.appeared(name: finalName, TransferFailure(error))
        }
    }

    /// Removes this job's part file; it stays in the journal when that fails (e.g. the connection is gone).
    private func removePart(_ entry: TransferPartJournal.Entry, from tree: FileTree) {
        guard (try? tree.removePart(entry.path)) != nil else { return }
        partJournal?.remove(entry)
    }

    // MARK: - Sync (two folders)

    /// Runs the plan's actions not done yet. Each is logged with the side it changed; failures are logged and the
    /// action is retried by Retry. Throws only to stop the job.
    private func runSync(_ request: SyncRequest, left: FileTree, right: FileTree) throws {
        let pending = request.actions.indices.filter { !isCompleted($0) }
        update { $0.progress.counting = true }
        var bytes: Int64 = 0
        for index in pending {
            let action = request.actions[index]
            guard case .copy(let to) = action.kind else { continue }
            let from = to.other
            let tree = from == .left ? left : right
            bytes += try size(of: tree.paths.join(request.root(from), action.path(from)), in: tree)
        }
        update {
            $0.progress.counting = false
            $0.progress.itemsTotal = pending.count + $0.progress.itemsDone
            $0.progress.bytesTotal = bytes + $0.progress.bytesDone
        }
        for index in pending {
            try checkpoint()
            if try runSyncAction(index, request, left: left, right: right) { markCompleted(index) }
        }
    }

    /// One action of a sync; true when it needs no retry (done, or left alone for good).
    private func runSyncAction(_ index: Int, _ request: SyncRequest, left: FileTree, right: FileTree) throws -> Bool {
        defer { update { $0.progress.itemsDone += 1 } }
        let action = request.actions[index]
        func tree(_ side: FolderSync.Side) -> FileTree { side == .left ? left : right }
        func path(_ side: FolderSync.Side) -> String { tree(side).paths.join(request.root(side), action.path(side)) }
        let shown = action.path
        let side = action.changes
        let target = path(side)
        let targetTree = tree(side)
        targetHost = .some(request.location(side).host)
        update { $0.syncSide = side }
        var existing: FileItem?
        guard try attempt(shown, { existing = try targetTree.item(at: target) }) else { return false }
        let trashedBefore = isSyncTrashed(index)

        guard case .copy = action.kind else {
            guard FolderSync.matches(existing, action.item(side)) else {
                record(shown, .failed(.changedSinceCompare), side: side)
                return true
            }
            guard try attempt(shown, { try targetTree.trash(target) }) else { return false }
            record(shown, .trashed, side: side)
            return true
        }

        let from = side.other
        let source = path(from)
        let sourceTree = tree(from)
        var found: FileItem?
        guard try attempt(shown, { found = try sourceTree.item(at: source) }) else { return false }
        guard let item = found else {
            record(shown, .failed(.noSuchItem), side: side)
            return false
        }
        guard item.kind == .file || item.kind == .folder else {
            record(shown, .notCopied, side: side)
            return true
        }
        let merging = item.kind == .folder && existing?.kind == .folder && ownFolder(target)
        guard merging || FolderSync.matches(existing, trashedBefore ? nil : action.item(side)) else {
            record(shown, .failed(.changedSinceCompare), side: side)
            addBytesDone(item.kind == .file ? item.size : 0)
            return true
        }
        let outcome: Outcome = merging ? .merged : (existing != nil || trashedBefore) ? .replaced : .copied
        let failuresBefore = failureCount()
        do {
            if let existing, !merging {
                // What is there goes to its side's Trash; a file over a file only once the new one is complete.
                let trashOld = {
                    do {
                        try targetTree.trash(target)
                    } catch {
                        throw TransferFailure.existingNotTrashed(TransferFailure(error))
                    }
                    self.markSyncTrashed(index)
                }
                if existing.kind == .file, item.kind == .file {
                    _ = try attempt(shown) {
                        try copyFile(item, from: source, in: sourceTree, to: target, in: targetTree, relative: shown,
                                     beforeRename: trashOld)
                    }
                } else {
                    guard try attempt(shown, trashOld) else { return false }
                    try copy(item, from: source, in: sourceTree, to: target, in: targetTree, relative: shown,
                             merging: false, isTopLevel: true)
                }
            } else {
                try copy(item, from: source, in: sourceTree, to: target, in: targetTree, relative: shown,
                         merging: merging, isTopLevel: true)
            }
        } catch is Cancelled {
            if item.kind == .folder, !merging, ownFolder(target) { try? targetTree.trash(target) }
            throw Cancelled()
        }
        guard failureCount() == failuresBefore else { return false }
        record(shown, outcome, side: side)
        return true
    }

    private func isSyncTrashed(_ index: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return syncTrashed.contains(index)
    }

    private func markSyncTrashed(_ index: Int) {
        lock.lock()
        syncTrashed.insert(index)
        lock.unlock()
    }

    // MARK: - Save (an edited copy over the server's file)

    /// Uploads the edited copy over `request.name` in the destination folder, after checking that the server's file is
    /// still `request.base` (or asking what to do when it is not). Failures are logged; throws only to stop the job.
    private func runSave(_ request: SaveRequest, from localTree: FileTree, to tree: FileTree) throws {
        let name = request.name
        let copy = sources[0].path
        let folder = destination.path
        let target = tree.paths.join(folder, name)
        defer { update { $0.progress.itemsDone = 1 } }
        guard let local = try localTree.item(at: copy), local.kind == .file else {
            record(name, .failed(.noSuchItem))
            return
        }
        update {
            $0.progress.itemsTotal = 1
            $0.progress.bytesTotal = local.size
        }
        let current = try tree.item(at: target)
        var path = target
        var outcome: Outcome = .saved
        switch request.base.change(to: current) {
        case .unchanged:
            break
        case .notAFile:
            record(name, .failed(.notAFile(name: name)))
            return
        case .changed, .missing:
            // Nobody to ask: upload nothing and keep the copy (Skip would replace it with the server's file).
            if policy == .ask, onConflict == nil { throw StopRequested() }
            switch try resolve(name: name, isFolder: false) {
            case .stop:
                throw StopRequested()
            case .replace:
                break
            case .skip:
                // Keep theirs: the server's file into the copy (nothing to take when it is gone).
                guard let current else {
                    record(name, .skipped)
                    return
                }
                _ = try attempt(name) {
                    try download(target, item: current, into: copy, in: localTree, from: tree,
                                 permissions: local.permissions)
                }
                return
            case .keepBoth:
                let newName = keepBothName(name, isFolder: false, in: folder, tree: tree)
                path = tree.paths.join(folder, newName)
                outcome = .keptBoth(newName)
            }
        }
        // Keep mine replaces what is there; after Keep Both, or when the file is gone, the name must be free.
        let replacing = outcome == .saved && current != nil
        _ = try attempt(name) {
            let written = try upload(copy, from: localTree, to: path, in: tree, replacing: replacing,
                                     permissions: current?.permissions ?? local.permissions)
            if written.replacedThroughTrash { outcome = .replaced }
            let version = try tree.item(at: path).map(RemoteFileVersion.init)
                ?? RemoteFileVersion(size: written.size, modified: nil)
            update {
                $0.saved = SaveResult(name: tree.paths.name(path), version: version, contentHash: written.hash,
                                      keptTheirs: false)
            }
            record(name, outcome)
        }
    }

    private struct Uploaded {
        var size: Int64
        var hash: String
        /// The server cannot rename over a file: its file went to its Trash first.
        var replacedThroughTrash = false
    }

    /// Writes the copy to a part file next to `path` (with `permissions`), then puts it in place: over the file there
    /// in one step when `replacing` (or through the server's Trash when the server cannot), else only if the name is
    /// still free.
    private func upload(_ copy: String, from localTree: FileTree, to path: String, in tree: FileTree, replacing: Bool,
                        permissions: UInt32?) throws -> Uploaded {
        let name = tree.paths.name(path)
        let part = tree.paths.join(tree.paths.parent(path), TransferNames.part(for: name))
        let entry = TransferPartJournal.Entry(host: destination.host, path: part)
        var hash = ContentHash()
        let size = try stream(copy, from: localTree, to: part, in: tree, entry: entry,
                              permissions: (permissions ?? 0o644) | 0o600) { hash.update($0) }
        tree.setAttributes(part, modified: nil, permissions: permissions)
        var uploaded = Uploaded(size: size, hash: hash.finalize())
        do {
            if replacing {
                do {
                    try tree.renameReplacing(part, to: path)
                } catch let error as SFTPError where error.statusCode == .unsupported {
                    do {
                        try tree.trash(path)
                    } catch {
                        throw TransferFailure.existingNotTrashed(TransferFailure(error))
                    }
                    try tree.rename(part, to: path)
                    uploaded.replacedThroughTrash = true
                }
            } else {
                do {
                    try tree.rename(part, to: path)
                } catch {
                    throw TransferFailure.appeared(name: name, TransferFailure(error))
                }
            }
            partJournal?.remove(entry)
        } catch {
            removePart(entry, from: tree)
            throw error
        }
        return uploaded
    }

    /// Keep theirs: the server's file into the copy (a part file next to it, renamed over it).
    private func download(_ path: String, item: FileItem, into copy: String, in localTree: FileTree, from tree: FileTree,
                          permissions: UInt32?) throws {
        let name = localTree.paths.name(copy)
        let part = localTree.paths.join(localTree.paths.parent(copy), TransferNames.part(for: name))
        let entry = TransferPartJournal.Entry(host: nil, path: part)
        update {
            $0.progress.bytesDone = 0
            $0.progress.bytesTotal = item.size
        }
        var hash = ContentHash()
        _ = try stream(path, from: tree, to: part, in: localTree, entry: entry, permissions: permissions ?? 0o644) {
            hash.update($0)
        }
        do {
            try localTree.renameReplacing(part, to: copy)
            partJournal?.remove(entry)
        } catch {
            removePart(entry, from: localTree)
            throw error
        }
        update {
            $0.saved = SaveResult(name: tree.paths.name(path), version: RemoteFileVersion(item),
                                  contentHash: hash.finalize(), keptTheirs: true)
        }
        record(tree.paths.name(path), .keptTheirs)
    }

    /// Streams `source` into a new part file (recorded in the journal until it is renamed or removed) and returns the
    /// bytes written, showing `current` (default: the source's name) as the file being written. On failure or cancel
    /// the part file is removed and its bytes are taken back. Copies, saves and Keep Theirs all write through here.
    private func stream(_ source: String, from sourceTree: FileTree, to part: String, in tree: FileTree,
                        entry: TransferPartJournal.Entry, permissions: UInt32, current: String? = nil,
                        _ each: (Data) -> Void = { _ in }) throws -> Int64 {
        update { $0.progress.current = current ?? sourceTree.paths.name(source) }
        let reader = try sourceTree.openForReading(source)
        defer { reader.close() }
        let writer = try tree.createFile(part, permissions: permissions)
        // Recorded until it is renamed or removed, so one left by a quit or crash is removed later.
        partJournal?.add(entry)
        var written: Int64 = 0
        do {
            while true {
                try checkpoint()
                let chunk = try reader.read()
                if chunk.isEmpty { break }
                try writer.write(chunk)
                each(chunk)
                written += Int64(chunk.count)
                addBytesDone(Int64(chunk.count))
            }
            try writer.finish()
        } catch {
            writer.abandon()
            removePart(entry, from: tree)
            // Bytes of a file that did not arrive do not count.
            addBytesDone(-written)
            throw error
        }
        return written
    }
}

extension TransferJob.SyncRequest {
    public func location(_ side: FolderSync.Side) -> FileLocation { side == .left ? left : right }
    public func root(_ side: FolderSync.Side) -> String { location(side).path }
}
