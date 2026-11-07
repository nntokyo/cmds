import CmdsCore
import Foundation

/// Why two folders cannot be compared or synced. `description` is English (API, CLI); the app shows `localizedText`.
enum FolderCompareError: Error, CustomStringConvertible {
    case sameFolder
    /// One folder is inside the other.
    case nested
    /// Too many items were read; a cut-short comparison is never synced.
    case truncated(Int)

    var description: String {
        switch self {
        case .sameFolder: return "Both sides are the same folder."
        case .nested: return "One folder is inside the other; compare two separate folders."
        case .truncated(let count):
            return "The comparison stopped after \(count) items (too many), so it cannot be synced. Compare smaller folders."
        }
    }

    var localizedText: String {
        switch self {
        case .sameFolder: return String(localized: "Both panes show the same folder.")
        case .nested: return String(localized: "One folder is inside the other. Compare two separate folders.")
        case .truncated(let count):
            return String(localized: "The comparison stopped after \(count) items (too many), so it cannot be synced. Compare smaller folders.")
        }
    }
}

/// One comparison of two folders (docs/guide/files.md "Comparing and syncing folders"), run off the main thread:
/// connects to the servers as needed (RemoteConnections), makes remote folders absolute (`~`, relative paths) and
/// compares them with `FolderSync.compare`. Cancel stops it before the next folder is listed.
final class FolderCompareTask: @unchecked Sendable {
    struct Output {
        /// The folders as compared (remote ones absolute).
        var left: FileLocation
        var right: FileLocation
        var comparison: FolderSync.Comparison
    }

    let left: FileLocation
    let right: FileLocation
    let includeHidden: Bool
    private let lock = NSLock()
    private var cancelled = false

    init(left: FileLocation, right: FileLocation, includeHidden: Bool) {
        self.left = left
        self.right = right
        self.includeHidden = includeHidden
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// Blocks (never on the main thread). `progress` gets the items read so far, on this thread.
    func run(progress: @escaping (Int) -> Void = { _ in }) throws -> Output {
        let leftTree = try RemoteConnections.shared.tree(for: left)
        let rightTree = try RemoteConnections.shared.tree(for: right)
        let leftRoot = Self.absolute(left, in: leftTree)
        let rightRoot = Self.absolute(right, in: rightTree)
        try Self.check(leftRoot, rightRoot)
        let comparison = try FolderSync.compare(left: leftTree, leftRoot.path, right: rightTree, rightRoot.path,
                                                options: .init(includeHidden: includeHidden),
                                                isCancelled: { [weak self] in self?.isCancelled ?? true },
                                                progress: progress)
        return Output(left: leftRoot, right: rightRoot, comparison: comparison)
    }

    /// Runs on a background queue; `completion` on the main queue.
    func start(progress: @escaping @MainActor (Int) -> Void,
               completion: @escaping @MainActor (Result<Output, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var last = Date.distantPast
            let result = Result {
                try self.run { count in
                    // At most a few updates a second.
                    guard Date().timeIntervalSince(last) > 0.2 else { return }
                    last = Date()
                    DispatchQueue.main.async { MainActor.assumeIsolated { progress(count) } }
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    /// A remote folder as typed (`~/x`, `x`, "") made absolute against the login folder.
    static func absolute(_ location: FileLocation, in tree: FileTree) -> FileLocation {
        guard case .remote(let host, let path) = location, let server = tree as? SFTPFileTree else { return location }
        return .remote(host: host, path: RemotePath.normalized(RemotePath.absolute(path, home: server.home)))
    }

    /// Refuses the same folder twice, and a folder inside the other (on the same Mac or host).
    static func check(_ left: FileLocation, _ right: FileLocation) throws {
        guard left.isSameTree(as: right) else { return }
        let paths: FilePathStyle = left.isRemote ? .server : .mac
        let a = left.isRemote ? RemotePath.normalized(left.path) : (left.path as NSString).standardizingPath
        let b = right.isRemote ? RemotePath.normalized(right.path) : (right.path as NSString).standardizingPath
        if a == b { throw FolderCompareError.sameFolder }
        if paths.isSameOrInside(a, b) || paths.isSameOrInside(b, a) { throw FolderCompareError.nested }
    }
}

/// `files.compare` and `files.sync` on the app's socket (docs/reference/api.md "Files panes"); refused on SSH panes'
/// sockets (not in `RemoteAPIPolicy.allowedMethods`).
@MainActor
enum FolderCompareAPI {
    static func perform(_ method: String, _ params: Params) async throws -> JSONValue {
        let left = try location(params, "left")
        let right = try location(params, "right")
        let direction = try params.value("direction", as: FolderSync.Direction.self,
                                         invalid: "direction must be leftToRight, rightToLeft or both") ?? .both
        let rule = try params.value("conflicts", as: FolderSync.ConflictRule.self,
                                    invalid: "conflicts must be newer, left, right or skip") ?? .newer
        let options = FolderSync.Options(direction: direction, deleteExtra: try params.bool("delete") ?? false,
                                         conflictRule: rule)
        let task = FolderCompareTask(left: left, right: right, includeHidden: try params.bool("hidden") ?? false)
        let output: FolderCompareTask.Output = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try task.run())
                } catch let error as FolderCompareError {
                    continuation.resume(throwing: RPCError.invalidParams(error.description))
                } catch {
                    // English text of a connection or listing failure (`SSHFailure`, `SFTPError`, errno).
                    continuation.resume(throwing: RPCError(code: 500, message: TransferFailure(error).description))
                }
            }
        }
        let decisions = FolderSync.plan(output.comparison.entries, options: options)
        var transfer: Int?
        if method == "files.sync" {
            guard !output.comparison.truncated else {
                throw RPCError(code: 500, message: FolderCompareError.truncated(output.comparison.itemsRead).description)
            }
            let actions = decisions.compactMap(\.action)
            if !actions.isEmpty {
                let request = TransferJob.SyncRequest(left: output.left, right: output.right, direction: direction,
                                                      actions: actions)
                transfer = TransferCenter.shared.startSync(request, from: nil).id
            }
        }
        let includeSame = try params.bool("same") ?? false
        let info = FolderCompareInfo(left: output.left, right: output.right, comparison: output.comparison,
                                     decisions: decisions, options: options,
                                     includeSame: method == "files.compare" && includeSame, transfer: transfer)
        return try .from(info)
    }

    /// `HOST:PATH`, or an absolute path on this Mac.
    private static func location(_ params: Params, _ key: String) throws -> FileLocation {
        let raw = try params.required(key)
        let location: FileLocation
        do {
            location = try FileLocation.parse(raw)
        } catch {
            throw RPCError.invalidParams("\(key): \(error)")
        }
        if !location.isRemote {
            guard raw.hasPrefix("/") else { throw RPCError.invalidParams("\(key) must be an absolute path or HOST:PATH") }
            guard FilesPane.isFolder(raw) else { throw RPCError.invalidParams("\(key) is not a folder: \(raw)") }
            return .local((raw as NSString).standardizingPath)
        }
        return location
    }
}
