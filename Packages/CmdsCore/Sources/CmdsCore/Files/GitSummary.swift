import Foundation

/// A repository's state for the sidebar's branch line (#174 G16): uncommitted changes and commits ahead / behind the
/// upstream, from `git status --porcelain=v2 --branch -z`.
public struct GitSummary: Codable, Equatable, Sendable {
    /// Changed, staged, untracked or conflicted paths (each counted once).
    public var changes: Int
    /// Commits not on the upstream / on it but not here; nil without an upstream.
    public var ahead: Int?
    public var behind: Int?
    /// `origin/main`; nil without one.
    public var upstream: String?

    public init(changes: Int, ahead: Int? = nil, behind: Int? = nil, upstream: String? = nil) {
        self.changes = changes
        self.ahead = ahead
        self.behind = behind
        self.upstream = upstream
    }

    /// The arguments for `git` (with `-C <folder>` before them).
    public static let statusArguments = ["--no-optional-locks", "status", "--porcelain=v2", "--branch", "-z",
                                         "--untracked-files=normal"]

    /// Parses the output of `statusArguments`; nil when it is not that format.
    public static func parse(_ output: Data) -> GitSummary? { parseWithPaths(output)?.summary }

    /// The summary and the changed paths, relative to the worktree's top level (a rename's both paths), at most
    /// `maxPaths` of them (`GitOverlap`).
    public static let maxPaths = 2_000
    public static func parseWithPaths(_ output: Data) -> (summary: GitSummary, paths: [String])? {
        var paths: [String] = []
        func keep(_ path: Substring?) {
            guard let path, !path.isEmpty, paths.count < maxPaths else { return }
            paths.append(String(path))
        }
        let fields = output.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        var summary = GitSummary(changes: 0)
        var sawBranch = false
        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            if field.hasPrefix("# ") {
                sawBranch = true
                if field.hasPrefix("# branch.upstream ") {
                    summary.upstream = String(field.dropFirst("# branch.upstream ".count))
                } else if field.hasPrefix("# branch.ab ") {
                    let parts = field.dropFirst("# branch.ab ".count).split(separator: " ")
                    if parts.count == 2, let ahead = Int(parts[0].dropFirst()), let behind = Int(parts[1].dropFirst()) {
                        summary.ahead = ahead
                        summary.behind = behind
                    }
                }
                continue
            }
            switch field.first {
            case "1":
                summary.changes += 1
                keep(field.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false).dropFirst(8).first)
            case "u":
                summary.changes += 1
                keep(field.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false).dropFirst(10).first)
            case "?":
                summary.changes += 1
                keep(field.dropFirst(2))
            case "2":
                summary.changes += 1
                keep(field.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false).dropFirst(9).first)
                // A rename or copy: the original path follows as its own field.
                if index < fields.count { keep(Substring(fields[index])) }
                index += 1
            default:
                continue  // "!" ignored files, or something new
            }
        }
        return sawBranch ? (summary, paths) : nil
    }

    /// The sidebar's short form after the branch: `±3 ↑1 ↓2` (zero parts left out; empty when clean and in step).
    public var badge: String {
        var parts: [String] = []
        if changes > 0 { parts.append("±\(changes)") }
        if let ahead, ahead > 0 { parts.append("↑\(ahead)") }
        if let behind, behind > 0 { parts.append("↓\(behind)") }
        return parts.joined(separator: " ")
    }
}

/// Files changed in more than one worktree of a repository (#174 G18): workspaces whose agents edit the same files in
/// separate worktrees run into conflicts when the branches are merged.
public struct GitOverlap: Codable, Equatable, Sendable {
    /// The other worktree's workspaces (several when they share it), sorted by id.
    public var workspaces: [String]
    /// The paths changed in both, relative to the worktrees' top level, sorted, at most `maxFiles`.
    public var files: [String]
    /// How many there are in all (`files` may be cut).
    public var count: Int

    public static let maxFiles = 20

    public init(workspaces: [String], files: [String], count: Int) {
        self.workspaces = workspaces
        self.files = files
        self.count = count
    }

    /// One checkout of a repository as a workspace sees it.
    public struct Checkout: Equatable, Sendable {
        public var workspace: String
        /// The repository the checkout belongs to (a linked worktree counts as its main repository).
        public var project: String
        /// The worktree's top level: two workspaces in the same one see the same files and never overlap.
        public var worktree: String
        public var paths: Set<String>

        public init(workspace: String, project: String, worktree: String, paths: Set<String>) {
            self.workspace = workspace
            self.project = project
            self.worktree = worktree
            self.paths = paths
        }
    }

    /// For each workspace, the other worktrees of the same project that changed some of its files, one entry per
    /// worktree with its workspaces (sorted by their first id). Workspaces without overlaps are left out.
    public static func find(_ checkouts: [Checkout]) -> [String: [GitOverlap]] {
        var result: [String: [GitOverlap]] = [:]
        let byProject = Dictionary(grouping: checkouts.filter { !$0.paths.isEmpty }, by: \.project)
        for (_, group) in byProject where group.count > 1 {
            for checkout in group {
                let others = Dictionary(grouping: group.filter { $0.worktree != checkout.worktree }, by: \.worktree)
                let overlaps = others.values
                    .compactMap { worktree -> GitOverlap? in
                        let shared = checkout.paths.intersection(worktree.reduce(into: Set<String>()) { $0.formUnion($1.paths) })
                        guard !shared.isEmpty else { return nil }
                        return GitOverlap(workspaces: worktree.map(\.workspace).sorted(),
                                          files: Array(shared.sorted().prefix(maxFiles)), count: shared.count)
                    }
                    .sorted { ($0.workspaces.first ?? "") < ($1.workspaces.first ?? "") }
                if !overlaps.isEmpty { result[checkout.workspace] = overlaps }
            }
        }
        return result
    }
}
