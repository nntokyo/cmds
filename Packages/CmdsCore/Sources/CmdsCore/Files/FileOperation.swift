import Foundation

/// A copy or move of files into a folder, run off the main thread (files pane, docs/guide/files.md "Copying and
/// moving").
///
/// - Copies use `copyfile(3)` (recursive, metadata included, symlinks copied as links) with a progress callback, so a
///   large copy reports its bytes and stops when cancelled; the partial item it was writing is then removed (it is
///   the operation's own output, never an existing file).
/// - Moves on the same volume are renames. Across volumes the item is copied and the original then moved to the
///   Trash: nothing is ever deleted for good.
/// - A name that is taken asks the main thread (`onConflict`): skip, replace (the existing item goes to the Trash)
///   or keep both (`FileNames.keepBoth`), optionally for all further conflicts.
public final class FileOperation: @unchecked Sendable {
    public enum Mode: Sendable { case copy, move }

    public enum Resolution: Sendable { case skip, replace, keepBoth, stop }

    public struct Status: Sendable {
        public var mode: Mode
        /// Top-level item being worked on (1-based) and how many there are.
        public var index: Int
        public var count: Int
        public var name: String
        public var bytesDone: Int64
        public var bytesTotal: Int64
    }

    public struct Failure: Sendable {
        public enum Reason: Sendable, Equatable {
            /// A folder into itself (or into a folder inside it).
            case intoItself
            /// Replacing would trash the folder the item comes from.
            case replaceContainsSource
            /// From the file system (English, or the system's localized error text).
            case error(String)
            /// A move across volumes was copied (the copy is in `created`), but the original could not be moved to
            /// the Trash; the error text as for `error`.
            case originalNotTrashed(String)
        }

        public var name: String
        public var reason: Reason
    }

    public let mode: Mode
    public let sources: [URL]
    public let destination: URL

    /// Main thread, throttled.
    public var onStatus: (@MainActor (Status) -> Void)?
    /// Main thread: a name is taken. Call `reply` once (on any thread) with the choice and whether it applies to all
    /// further conflicts.
    public var onConflict: (@MainActor (_ name: String, _ isFolder: Bool, _ reply: @escaping @Sendable (Resolution, Bool) -> Void) -> Void)?
    /// Main thread, once. `created` are the new items' URLs (to select them).
    public var onFinish: (@MainActor (_ created: [URL], _ failures: [Failure], _ cancelled: Bool) -> Void)?

    /// Moves an item to the Trash (replaced items, originals of moves across volumes). Tests use a folder of their own.
    public var trash: @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Tests: called on the worker thread with each progress report of `copyfile`.
    var onCopyProgress: (@Sendable (Int64) -> Void)?
    /// Tests: moves are copied and their originals trashed, as across volumes.
    var movesAcrossVolumes = false

    private let lock = NSLock()
    private var cancelledFlag = false
    private var status: Status
    private var lastStatusPost = Date.distantPast
    /// Worker thread only, set when `run` starts.
    private var destinationVolume: NSObject?

    public init(mode: Mode, sources: [URL], destination: URL) {
        self.mode = mode
        self.sources = sources
        self.destination = destination
        status = Status(mode: mode, index: 0, count: sources.count, name: "", bytesDone: 0, bytesTotal: 0)
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledFlag
    }

    public func cancel() {
        lock.lock()
        cancelledFlag = true
        lock.unlock()
    }

    public func start() {
        let thread = Thread { [self] in run() }
        thread.name = "cmds.file-operation"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    // MARK: - Worker

    /// At most this often a progress report while a file is copied (the start and end of each item always report).
    private static let statusInterval: TimeInterval = 0.1

    /// What to do with one source.
    private enum Step {
        case transfer(to: URL)
        /// Nothing to do; `countBytes` when its bytes still count as done (a skipped conflict).
        case skip(countBytes: Bool)
        case fail(Failure.Reason)
        case stop
    }

    private func run() {
        var created: [URL] = []
        var failures: [Failure] = []
        var applyToAll: Resolution?
        var stopped = false
        destinationVolume = Self.volume(of: destination)
        let sizes = measure()
        status.bytesTotal = sizes.reduce(0, +)

        items: for (index, source) in sources.enumerated() {
            if isCancelled { break }
            let name = source.lastPathComponent
            let size = index < sizes.count ? sizes[index] : 0
            status.index = index + 1
            status.name = name
            post(force: true)
            let target: URL
            switch step(for: source, applyToAll: &applyToAll) {
            case .transfer(let url):
                target = url
            case .skip(let countBytes):
                if countBytes { status.bytesDone += size }
                continue items
            case .fail(let reason):
                failures.append(Failure(name: name, reason: reason))
                continue items
            case .stop:
                stopped = true
                break items
            }
            let base = status.bytesDone
            do {
                let problem = try transfer(source, to: target, base: base)
                created.append(target)
                if let problem { failures.append(Failure(name: name, reason: problem)) }
            } catch CopyError.cancelled {
                // Our own partial output, never a file that was there before (the target did not exist).
                try? FileManager.default.removeItem(at: target)
                break items
            } catch {
                if case CopyError.failed = error, Self.exists(target), !created.contains(target) {
                    try? FileManager.default.removeItem(at: target)
                }
                failures.append(Failure(name: name, reason: .error((error as? CopyError)?.message ?? error.localizedDescription)))
            }
            status.bytesDone = base + size
            post(force: true)
        }
        let cancelled = isCancelled || stopped
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { onFinish?(created, failures, cancelled) }
        }
    }

    /// Bytes to copy per source (moves within a volume are renames: nothing to count); fewer when cancelled meanwhile.
    private func measure() -> [Int64] {
        var sizes: [Int64] = []
        for source in sources {
            sizes.append(isRename(source) ? 0 : Self.byteCount(source))
            if isCancelled { break }
        }
        return sizes
    }

    /// Where `source` goes: a name that is taken asks (or follows "apply to all"); Replace trashes the existing item.
    private func step(for source: URL, applyToAll: inout Resolution?) -> Step {
        let name = source.lastPathComponent
        let isFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if FileNames.isSameOrInside(destination.path, source.path) { return .fail(.intoItself) }
        let target = destination.appendingPathComponent(name, isDirectory: isFolder)
        if FileNames.isSamePath(source, target) {
            // Into its own folder: a copy gets a new name, a move has nothing to do.
            guard mode == .copy else { return .skip(countBytes: false) }
            return .transfer(to: destination.appendingPathComponent(keepBothName(name, isFolder: isFolder)))
        }
        guard Self.exists(target) else { return .transfer(to: target) }
        switch applyToAll ?? ask(name: name, isFolder: isFolder, applyToAll: &applyToAll) {
        case .stop:
            return .stop
        case .skip:
            return .skip(countBytes: true)
        case .keepBoth:
            return .transfer(to: destination.appendingPathComponent(keepBothName(name, isFolder: isFolder)))
        case .replace:
            if FileNames.isSameOrInside(source.path, target.path) { return .fail(.replaceContainsSource) }
            do {
                try trash(target)
            } catch {
                return .fail(.error(error.localizedDescription))
            }
            return .transfer(to: target)
        }
    }

    /// A move within the destination's volume is a rename; anything else is copied, and a move then trashes the
    /// original. Throws when nothing was transferred; returns the problem of a move whose copy is done but whose
    /// original is still there.
    private func transfer(_ source: URL, to target: URL, base: Int64) throws -> Failure.Reason? {
        if isRename(source) {
            try FileManager.default.moveItem(at: source, to: target)
            return nil
        }
        try copy(source, to: target, base: base)
        guard mode == .move else { return nil }
        do {
            try trash(source)
        } catch {
            return .originalNotTrashed(error.localizedDescription)
        }
        return nil
    }

    private func isRename(_ source: URL) -> Bool {
        mode == .move && !movesAcrossVolumes && destinationVolume != nil && Self.volume(of: source) == destinationVolume
    }

    private func keepBothName(_ name: String, isFolder: Bool) -> String {
        FileNames.keepBoth(name, isFolder: isFolder) { Self.exists(destination.appendingPathComponent($0)) }
    }

    /// Asks the main thread and waits (this is the worker thread).
    private func ask(name: String, isFolder: Bool, applyToAll: inout Resolution?) -> Resolution {
        let semaphore = DispatchSemaphore(value: 0)
        let answer = Answer()
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                guard let onConflict else {
                    answer.set(.skip, false)
                    semaphore.signal()
                    return
                }
                onConflict(name, isFolder) { resolution, all in
                    answer.set(resolution, all)
                    semaphore.signal()
                }
            }
        }
        semaphore.wait()
        let (resolution, all) = answer.get()
        if all, resolution != .stop { applyToAll = resolution }
        return isCancelled ? .stop : resolution
    }

    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (Resolution, Bool) = (.skip, false)
        func set(_ resolution: Resolution, _ all: Bool) { lock.lock(); value = (resolution, all); lock.unlock() }
        func get() -> (Resolution, Bool) { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func post(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastStatusPost) > Self.statusInterval else { return }
        lastStatusPost = now
        let snapshot = status
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { onStatus?(snapshot) }
        }
    }

    // MARK: - copyfile

    enum CopyError: Error {
        case cancelled
        case failed(String)

        var message: String {
            switch self {
            case .cancelled: return "cancelled"
            case .failed(let message): return message
            }
        }
    }

    /// State shared with the C callback of one `copyfile` call.
    private final class CopyContext {
        let operation: FileOperation
        let base: Int64
        /// Bytes of files finished in this call, and of the file being copied.
        var finished: Int64 = 0
        var current: Int64 = 0
        var errorPath: String?
        var errorCode: Int32 = 0

        init(operation: FileOperation, base: Int64) {
            self.operation = operation
            self.base = base
        }
    }

    private static let callback: copyfile_callback_t = { what, stage, state, source, _, context in
        guard let context else { return COPYFILE_CONTINUE }
        let copy = Unmanaged<CopyContext>.fromOpaque(context).takeUnretainedValue()
        if copy.operation.isCancelled { return COPYFILE_QUIT }
        if stage == COPYFILE_ERR {
            copy.errorPath = source.map { String(cString: $0) }
            copy.errorCode = errno
            return COPYFILE_QUIT
        }
        if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
            var copied: off_t = 0
            if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 { copy.current = Int64(copied) }
            copy.operation.status.bytesDone = copy.base + copy.finished + copy.current
            copy.operation.onCopyProgress?(copy.current)
            copy.operation.post()
        } else if what == COPYFILE_RECURSE_FILE, stage == COPYFILE_FINISH {
            copy.finished += copy.current
            copy.current = 0
        }
        return COPYFILE_CONTINUE
    }

    private func copy(_ source: URL, to target: URL, base: Int64) throws {
        guard let state = copyfile_state_alloc() else { throw CopyError.failed("copyfile_state_alloc failed") }
        defer { copyfile_state_free(state) }
        let context = CopyContext(operation: self, base: base)
        let unmanaged = Unmanaged.passRetained(context)
        defer { unmanaged.release() }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(Self.callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), unmanaged.toOpaque())
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW | COPYFILE_EXCL)
        let result = copyfile(source.path, target.path, state, flags)
        guard result == 0 else {
            if isCancelled { throw CopyError.cancelled }
            let code = context.errorCode != 0 ? context.errorCode : errno
            let reason = String(cString: strerror(code))
            let path = context.errorPath.map { " (\(($0 as NSString).lastPathComponent))" } ?? ""
            throw CopyError.failed("\(reason)\(path)")
        }
    }

    // MARK: - File system helpers

    /// Also true for a symlink whose target is missing.
    public static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    public static func volume(of url: URL) -> NSObject? {
        let probe = exists(url) ? url : url.deletingLastPathComponent()
        return (try? probe.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier) as? NSObject
    }

    /// Bytes of a file, or of everything in a folder (symlinks not followed).
    public static func byteCount(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isDirectory != true { return Int64(values.fileSize ?? 0) }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [],
                                                        errorHandler: { _, _ in true })
        while let item = enumerator?.nextObject() as? URL {
            if let values = try? item.resourceValues(forKeys: keys), values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}
