import Foundation

/// A git worktree cmds created for a worktree workspace (docs/guide/workspaces-and-panes.md "Worktree workspaces").
/// Only worktrees with a record are ever offered for removal.
public struct WorktreeRecord: Codable, Equatable, Sendable {
    /// The worktree's folder (absolute, symbolic links resolved).
    public var path: String
    /// The repository's main working tree.
    public var repository: String
    /// The branch cmds created for it.
    public var branch: String
    /// What the branch started from, as given to git (`origin/master`, `develop`, …): Show Changes compares with it.
    public var base: String
    public var created: Date

    public init(path: String, repository: String, branch: String, base: String, created: Date = Date()) {
        self.path = path
        self.repository = repository
        self.branch = branch
        self.base = base
        self.created = created
    }

    /// The part of the record the socket API shows in `workspace.list` (`WorkspaceInfo.worktree`).
    public var info: WorktreeInfo { WorktreeInfo(path: path, branch: branch, base: base) }
}

/// A workspace's worktree that cmds created (`workspace.list`).
public struct WorktreeInfo: Codable, Equatable, Sendable {
    public var path: String
    public var branch: String
    public var base: String

    public init(path: String, branch: String, base: String) {
        self.path = path
        self.branch = branch
        self.base = base
    }
}

/// `worktrees.json` in the support directory (`CMDS_SUPPORT_DIR` for an isolated instance):
/// `{"version": 1, "worktrees": [...]}`. Loaded through `StoredFile` (a damaged file is moved aside, never
/// overwritten); written atomically, readable by the user only.
public enum WorktreeStore {
    public static let fileName = "worktrees.json"
    static let version = 1

    private struct File: Codable {
        var version: Int
        var worktrees: [WorktreeRecord]
    }

    public static func url(supportDirectory: URL = CmdsEnv.supportDirectoryURL()) -> URL {
        supportDirectory.appendingPathComponent(fileName)
    }

    public struct Loaded {
        /// Empty when the file is missing or could not be read.
        public var records: [WorktreeRecord]
        public var error: Error?
        /// Where an undecodable file was moved (kept).
        public var movedAside: URL?
        /// The file could not be read and is still in place: saving would overwrite it.
        public var saveBlocked: Bool { error != nil && movedAside == nil }
    }

    public static func load(from url: URL, now: Date = Date()) -> Loaded {
        switch StoredFile.load(File.self, from: url, decoder: decoder, now: now) {
        case .missing:
            return Loaded(records: [])
        case .loaded(let file):
            return Loaded(records: file.worktrees)
        case .unreadable(let error, .success(let moved)):
            return Loaded(records: [], error: error, movedAside: moved)
        case .unreadable(let error, .failure):
            return Loaded(records: [], error: error)
        }
    }

    public static func save(_ records: [WorktreeRecord], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(File(version: version, worktrees: records)).write(to: url, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
