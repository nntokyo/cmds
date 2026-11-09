#if os(macOS)
import Foundation

/// Creating, comparing and removing worktrees with git (docs/guide/workspaces-and-panes.md "Worktree workspaces").
/// Every function blocks on git: call them off the main thread.
public enum Worktrees {
    /// What `cmds new --worktree` asked for.
    public struct Request: Equatable, Sendable {
        public var branch: String
        /// Branch, remote branch or commit to start from; nil = the repository's default branch.
        public var base: String?
        /// Absolute folder for the worktree; nil = `WorktreePaths.defaultPath`.
        public var path: String?

        public init(branch: String, base: String? = nil, path: String? = nil) {
            self.branch = branch
            self.base = base
            self.path = path
        }
    }

    public struct Creation: Sendable {
        public var record: WorktreeRecord
        /// Set when `git fetch` failed (offline, no access): the branch then starts from what was fetched before.
        public var fetchWarning: String?
    }

    /// The repository of a directory: its main working tree and the remote to fetch from (`origin`, else the first).
    struct Repository {
        var root: String
        var remote: String?
        var remotes: [String]
    }

    static func repository(of directory: String) throws -> Repository {
        guard FileManager.default.fileExists(atPath: directory) else { throw WorktreeError.notARepository(directory) }
        let output = try Git.run(["rev-parse", "--path-format=absolute", "--git-common-dir", "--is-bare-repository"],
                                 in: directory)
        let lines = output.text.split(separator: "\n").map(String.init)
        guard output.succeeded, lines.count == 2 else { throw WorktreeError.notARepository(directory) }
        guard lines[1] == "false" else { throw WorktreeError.bareRepository(directory) }
        let commonDir = URL(fileURLWithPath: lines[0]).standardizedFileURL
        // `<root>/.git`, except for submodules (`<superproject>/.git/modules/<name>`): their own top level then.
        let root = WorktreePaths.canonical(commonDir.lastPathComponent == ".git"
            ? commonDir.deletingLastPathComponent().path
            : try Git.check(["rev-parse", "--show-toplevel"], in: directory))
        let remotes = try Git.check(["remote"], in: root).split(separator: "\n").map(String.init)
        return Repository(root: root, remote: remotes.contains("origin") ? "origin" : remotes.first, remotes: remotes)
    }

    // MARK: - Create

    /// Fetches, then creates branch `request.branch` from the base and a worktree for it (`git worktree add --no-track
    /// -b`): the new branch has no upstream, so a plain `git push` never goes to the base. An existing branch, an
    /// existing path or a path inside the repository's working tree is an error, before anything is changed.
    public static func create(_ request: Request, from directory: String, now: Date = Date()) throws -> Creation {
        let repository = try repository(of: directory)
        let branch = try checkedBranch(request.branch, in: repository.root)
        let target = request.path.map { ($0 as NSString).expandingTildeInPath }
            ?? WorktreePaths.defaultPath(repository: repository.root, branch: branch)
        let path = try WorktreePaths.checkNew(target, repository: repository.root)

        var fetchWarning: String?
        if let remote = fetchRemote(for: request.base, in: repository) {
            let fetch = try Git.run(["fetch", "--quiet", remote], in: repository.root, timeout: Git.fetchTimeout)
            if !fetch.succeeded { fetchWarning = "git fetch \(remote) failed: \(fetch.message)" }
        }
        let base = try request.base.map { try startPoint($0, in: repository) } ?? defaultBase(in: repository)
        // Checked again after the fetch: a branch of that name on the remote is taken too (pushing the new branch
        // would collide with it), and so is a local one created meanwhile.
        _ = try checkedBranch(branch, in: repository.root, remote: repository.remote)
        try Git.check(["worktree", "add", "--quiet", "--no-track", "-b", branch, path, base], in: repository.root)
        let record = WorktreeRecord(path: WorktreePaths.canonical(path), repository: repository.root, branch: branch,
                                    base: base, created: now)
        return Creation(record: record, fetchWarning: fetchWarning)
    }

    /// A valid name for a new branch (`git check-ref-format --branch`, no `@{-1}` shorthands), not taken yet.
    static func checkedBranch(_ raw: String, in root: String, remote: String? = nil) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.hasPrefix("-"), name != "HEAD", !name.contains("@{") else {
            throw WorktreeError.invalidBranch(raw)
        }
        let format = try Git.run(["check-ref-format", "--branch", name], in: root)
        guard format.succeeded, format.text == name else { throw WorktreeError.invalidBranch(raw) }
        let refs = ["refs/heads/" + name] + (remote.map { ["refs/remotes/\($0)/\(name)"] } ?? [])
        for ref in refs where try Git.run(["show-ref", "--verify", "--quiet", ref], in: root).succeeded {
            throw WorktreeError.branchExists(name)
        }
        return name
    }

    /// The remote whose branches the base comes from: the remote named in `base` (`upstream/main`), else the default.
    static func fetchRemote(for base: String?, in repository: Repository) -> String? {
        if let base, let named = repository.remotes.first(where: { base.hasPrefix($0 + "/") }) { return named }
        return repository.remote
    }

    /// What to start a branch from, for a base the user named: a remote branch (`origin/main`, preferred when both
    /// exist, since it was just fetched), a local branch, a tag or a commit.
    static func startPoint(_ raw: String, in repository: Repository) throws -> String {
        let base = raw.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !base.hasPrefix("-") else { throw WorktreeError.unknownBase(raw) }
        func exists(_ ref: String) throws -> Bool {
            try Git.run(["show-ref", "--verify", "--quiet", ref], in: repository.root).succeeded
        }
        if repository.remotes.contains(where: { base.hasPrefix($0 + "/") }), try exists("refs/remotes/" + base) {
            return base
        }
        if let remote = repository.remote, try exists("refs/remotes/\(remote)/\(base)") { return "\(remote)/\(base)" }
        if try exists("refs/heads/" + base) { return base }
        if try Git.run(["rev-parse", "--verify", "--quiet", base + "^{commit}"], in: repository.root).succeeded {
            return base
        }
        throw WorktreeError.unknownBase(raw)
    }

    /// The repository's default branch: the remote's HEAD (`origin/main`), else `main` or `master`, else the branch
    /// checked out in the main working tree.
    static func defaultBase(in repository: Repository) throws -> String {
        if let remote = repository.remote {
            let head = try Git.run(["symbolic-ref", "--quiet", "refs/remotes/\(remote)/HEAD"], in: repository.root)
            let prefix = "refs/remotes/"
            if head.succeeded, head.text.hasPrefix(prefix) { return String(head.text.dropFirst(prefix.count)) }
        }
        for name in ["main", "master"] {
            if let base = try? startPoint(name, in: repository) { return base }
        }
        let current = try Git.run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: repository.root)
        if current.succeeded, !current.text.isEmpty, let base = try? startPoint(current.text, in: repository) {
            return base
        }
        throw WorktreeError.noDefaultBranch
    }

    // MARK: - Changes

    public struct Changes: Sendable {
        /// A unified diff with `#` lines on top (what is compared, the commits): the preview shows them dimmed.
        public var text: String
        public var base: String
        /// The working tree's branch (nil when detached).
        public var branch: String?
        public var root: String
    }

    /// Diffs that are longer are cut (the preview stays usable); untracked files beyond `maxUntracked` or larger than
    /// `maxUntrackedSize` are listed without content.
    static let maxDiffSize = 8 << 20
    static let maxUntracked = 200
    static let maxUntrackedSize = 1 << 20
    static let maxCommits = 200

    /// Show Changes: what the working tree of `directory` changed since it left `base` (default: the repository's
    /// default branch): the commits `base..HEAD`, then one diff from the merge base to the working tree (committed,
    /// staged and unstaged changes together) plus the untracked files. Nothing is fetched or changed.
    public static func changes(in directory: String, base requestedBase: String?) throws -> Changes {
        let repository = try repository(of: directory)
        let top = try Git.check(["rev-parse", "--show-toplevel"], in: directory)
        let base = try requestedBase.map { try startPoint($0, in: repository) } ?? defaultBase(in: repository)
        let head = try Git.run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: top)
        let branch = head.succeeded && !head.text.isEmpty ? head.text : nil
        let mergeBase = try Git.run(["merge-base", base, "HEAD"], in: top)
        let from = mergeBase.succeeded ? mergeBase.text : base

        var text = "# Changes in \(top)" + (branch.map { " (\($0))" } ?? "") + " since \(base)"
        text += mergeBase.succeeded ? " (merge base \(from.prefix(10)))" : ""
        text += ", working tree included\n"
        let log = try Git.check(["log", "--no-color", "--no-decorate", "--format=%h %s", "-n", String(maxCommits + 1),
                                 "\(base)..HEAD"], in: top)
        let commits = log.split(separator: "\n")
        text += commits.isEmpty ? "# No commits since \(base).\n" : "# Commits (newest first):\n"
        for commit in commits.prefix(maxCommits) { text += "#   \(commit)\n" }
        if commits.count > maxCommits { text += "#   …\n" }
        text += "\n"

        let diff = try Git.run(["diff", "--no-color", "--no-ext-diff", "--no-textconv", from, "--"], in: top)
        guard diff.succeeded else { throw WorktreeError.gitFailed(command: "git diff", message: diff.message) }
        var body = String(decoding: diff.stdout, as: UTF8.self)

        let untracked = try Git.run(["ls-files", "--others", "--exclude-standard", "-z"], in: top)
        let files = untracked.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        for (index, file) in files.enumerated() {
            guard body.utf8.count < maxDiffSize else { break }
            let size = (try? FileManager.default.attributesOfItem(atPath: (top as NSString).appendingPathComponent(file))[.size]
                as? Int) ?? 0
            guard index < maxUntracked, size <= maxUntrackedSize else {
                body += "# Untracked, not shown: \(file)\n"
                continue
            }
            // Exit status 1 = the file differs from nothing, as expected.
            let added = try Git.run(["diff", "--no-index", "--no-color", "--no-ext-diff", "--", "/dev/null", file], in: top)
            if added.status <= 1 { body += String(decoding: added.stdout, as: UTF8.self) }
        }
        if body.utf8.count > maxDiffSize {
            body = String(decoding: body.utf8.prefix(maxDiffSize), as: UTF8.self) + "\n# … cut: the diff is too long.\n"
        }
        text += body.isEmpty ? "# No changes in the working tree compared with the merge base.\n" : body
        return Changes(text: text, base: base, branch: branch, root: top)
    }

    // MARK: - Remove

    /// Why `record`'s worktree must stay; empty when it may be removed. Reads only local state (nothing is fetched):
    /// a remote branch not fetched yet counts as not pushed, which errs on the side of keeping it.
    public static func removalRefusals(_ record: WorktreeRecord) throws -> [WorktreeRefusal] {
        guard FileManager.default.fileExists(atPath: record.path) else { return [.notAWorktree] }
        let listed = WorktreeOutput.parseList(try Git.check(["worktree", "list", "--porcelain"], in: record.repository))
        // The first entry is the main working tree, which is never removed.
        guard let entry = listed.dropFirst().first(where: { WorktreePaths.canonical($0.path) == record.path }) else {
            return [.notAWorktree]
        }
        var refusals: [WorktreeRefusal] = entry.locked ? [.locked] : []
        let status = try Git.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: record.path)
        guard status.succeeded else { throw WorktreeError.gitFailed(command: "git status", message: status.message) }
        let counts = WorktreeOutput.countStatus(status.stdout)
        if counts.changed > 0 { refusals.append(.uncommittedChanges(counts.changed)) }
        if counts.untracked > 0 { refusals.append(.untrackedFiles(counts.untracked)) }
        var notPushed = ["rev-list", "--count", "HEAD", "--not", "--remotes"]
        if try Git.run(["rev-parse", "--verify", "--quiet", record.base + "^{commit}"], in: record.path).succeeded {
            notPushed.append(record.base)
        }
        let unpushed = Int(try Git.check(notPushed, in: record.path)) ?? 0
        if unpushed > 0 { refusals.append(.unpushedCommits(unpushed)) }
        return refusals
    }

    /// Removes `record`'s worktree with `git worktree remove` (no `--force`: git itself refuses a dirty worktree too)
    /// after `removalRefusals` found nothing. Files git ignores (build output, dependencies) go with the folder; the
    /// branch stays. An empty `<repo>-worktrees` folder left behind is removed.
    public static func remove(_ record: WorktreeRecord) throws {
        let refusals = try removalRefusals(record)
        guard refusals.isEmpty else { throw WorktreeError.refused(refusals) }
        try Git.check(["worktree", "remove", record.path], in: record.repository)
        let parent = URL(fileURLWithPath: record.path).deletingLastPathComponent()
        let defaultParent = URL(fileURLWithPath: WorktreePaths.defaultPath(repository: record.repository, branch: "x"))
            .deletingLastPathComponent()
        if WorktreePaths.canonical(parent.path) == WorktreePaths.canonical(defaultParent.path),
           (try? FileManager.default.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: parent)
        }
    }
}
#endif
