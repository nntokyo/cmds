import Foundation

/// The temporary `.cmds-part-…` files transfers are writing, recorded in the support folder so that ones left behind
/// when cmds quit or crashed in the middle of a transfer are removed later: on this Mac at the next launch, on a
/// server the next time cmds connects to it (docs/internals/files-sftp.md). Only paths recorded here by an earlier
/// run, and only part names (`FileTree.removePart` refuses any other), are ever removed.
public final class TransferPartJournal: @unchecked Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        /// nil: this Mac.
        public var host: String?
        public var path: String

        public init(host: String?, path: String) {
            self.host = host
            self.path = path
        }
    }

    public static let fileName = "transfer-parts.json"

    public static func url(supportDirectory: URL = CmdsEnv.supportDirectoryURL()) -> URL {
        supportDirectory.appendingPathComponent(fileName)
    }

    private let url: URL?
    private let lock = NSLock()
    private var entries: Set<Entry>
    /// Entries of earlier runs: the only ones `clean` removes (this run's are files being written).
    private var leftovers: Set<Entry>

    /// `url` nil keeps the journal in memory (tests).
    public init(url: URL?) {
        self.url = url
        let saved = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }
        entries = Set(saved ?? [])
        leftovers = entries
    }

    /// A transfer created this part file.
    public func add(_ entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        entries.insert(entry)
        save()
    }

    /// The part file is gone (renamed into place or removed).
    public func remove(_ entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        leftovers.remove(entry)
        guard entries.remove(entry) != nil else { return }
        save()
    }

    /// Part files of earlier runs on `host` (nil: this Mac).
    public func leftovers(host: String?) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return leftovers.filter { $0.host == host }.sorted { $0.path < $1.path }
    }

    /// Removes the part files earlier runs left on `host` from `tree`, and forgets each one that is gone (removed now,
    /// or not there any more). One that cannot be removed now (no connection, no permission) is tried again next time.
    /// Returns how many were forgotten as gone. Blocks; never on the main thread.
    @discardableResult
    public func clean(host: String?, tree: FileTree) -> Int {
        var gone = 0
        for entry in leftovers(host: host) {
            do {
                try tree.removePart(entry.path)
                gone += 1
            } catch {
                guard !TransferNames.isPart(tree.paths.name(entry.path)) else { continue }
                // Not a part name (a damaged journal): never removed, so not kept either.
            }
            remove(entry)
        }
        return gone
    }

    /// Called with the lock held.
    private func save() {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(entries.sorted { ($0.host ?? "", $0.path) < ($1.host ?? "", $1.path) })
        else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
