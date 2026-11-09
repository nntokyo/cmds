import Foundation

/// Why a worktree is not created, compared or removed. `description` is English (socket API, CLI); the Mac app has its
/// own text (CoreErrorText.swift).
public enum WorktreeError: Error, Equatable, CustomStringConvertible {
    case gitMissing
    case notARepository(String)
    case bareRepository(String)
    case invalidBranch(String)
    case branchExists(String)
    case pathNotAbsolute(String)
    case pathExists(String)
    case pathInsideRepository(String)
    case unknownBase(String)
    case noDefaultBranch
    case notCreatedByCmds(String)
    case refused([WorktreeRefusal])
    case gitFailed(command: String, message: String)

    public var description: String {
        switch self {
        case .gitMissing: return "git is not installed (install the Xcode Command Line Tools)"
        case .notARepository(let path): return "not in a git repository: \(path)"
        case .bareRepository(let path): return "a bare repository has no working tree to start from: \(path)"
        case .invalidBranch(let name): return "not a valid branch name: \(name)"
        case .branchExists(let name): return "branch \(name) already exists"
        case .pathNotAbsolute(let path): return "the worktree path must be absolute: \(path)"
        case .pathExists(let path): return "\(path) already exists"
        case .pathInsideRepository(let path): return "\(path) is inside the repository's working tree"
        case .unknownBase(let name): return "no branch or commit named \(name)"
        case .noDefaultBranch: return "cannot tell the repository's default branch; give --base"
        case .notCreatedByCmds(let path): return "cmds did not create the worktree \(path); it is never removed by cmds"
        case .refused(let refusals): return "worktree kept: " + refusals.map(\.description).joined(separator: ", ")
        case .gitFailed(let command, let message): return "\(command) failed: \(message)"
        }
    }
}

/// Why `Worktrees.remove` keeps a worktree: anything that could still be someone's work.
public enum WorktreeRefusal: Equatable, Sendable, CustomStringConvertible {
    /// The folder is no longer a worktree of the recorded repository (moved, removed or pruned).
    case notAWorktree
    /// `git worktree lock`ed.
    case locked
    /// Changed, staged, deleted or conflicted tracked files.
    case uncommittedChanges(Int)
    /// Files git does not track and does not ignore.
    case untrackedFiles(Int)
    /// Commits on the worktree's HEAD that are on no remote branch and not on the base.
    case unpushedCommits(Int)

    public var description: String {
        switch self {
        case .notAWorktree: return "no longer a worktree of its repository"
        case .locked: return "locked"
        case .uncommittedChanges(let count): return "\(count) uncommitted change\(count == 1 ? "" : "s")"
        case .untrackedFiles(let count): return "\(count) untracked file\(count == 1 ? "" : "s")"
        case .unpushedCommits(let count): return "\(count) commit\(count == 1 ? "" : "s") not pushed"
        }
    }
}

/// Paths of worktree workspaces (no git involved).
public enum WorktreePaths {
    /// Where `cmds new --worktree BRANCH` puts the worktree without `--path`: `<parent>/<repo>-worktrees/<branch>` next
    /// to the repository, with `/` in the branch name replaced by `-`. Outside the repository's working tree (its
    /// build tools, searches, file watchers and `git status` never see it) and on the same volume.
    public static func defaultPath(repository: String, branch: String) -> String {
        let repo = URL(fileURLWithPath: canonical(repository), isDirectory: true)
        let folder = branch.replacingOccurrences(of: "/", with: "-")
        return repo.deletingLastPathComponent()
            .appendingPathComponent(repo.lastPathComponent + "-worktrees", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true).path
    }

    /// `path` with `.`/`..` removed and symbolic links of its existing part resolved (`/tmp/x` → `/private/tmp/x`),
    /// for comparing paths. Unlike `URL.resolvingSymlinksInPath`, never strips `/private`.
    public static func canonical(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var missing: [String] = []
        while true {
            if let resolved = realpath(existing.path, nil) {
                defer { free(resolved) }
                var url = URL(fileURLWithPath: String(cString: resolved))
                for component in missing.reversed() { url.appendPathComponent(component) }
                return url.path
            }
            let parent = existing.deletingLastPathComponent()
            if parent.path == existing.path { return URL(fileURLWithPath: path).standardizedFileURL.path }
            missing.append(existing.lastPathComponent)
            existing = parent
        }
    }

    /// `path` is `folder` or inside it (both canonical).
    public static func isInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// Checks a new worktree's location: absolute, not existing (also no broken link), not inside the repository's
    /// main working tree. Returns the canonical path.
    public static func checkNew(_ path: String, repository: String) throws -> String {
        guard path.hasPrefix("/") else { throw WorktreeError.pathNotAbsolute(path) }
        let canonicalPath = canonical(path)
        if (try? FileManager.default.attributesOfItem(atPath: canonicalPath)) != nil
            || (try? FileManager.default.attributesOfItem(atPath: path)) != nil {
            throw WorktreeError.pathExists(path)
        }
        if isInside(canonicalPath, canonical(repository)) { throw WorktreeError.pathInsideRepository(path) }
        return canonicalPath
    }

    /// The working tree a local directory belongs to: the nearest folder upwards with a `.git` entry (file or folder).
    /// Reads only the file system (no git process).
    public static func workingTreeRoot(of directory: String) -> String? {
        let fileManager = FileManager.default
        var url = URL(fileURLWithPath: canonical(directory), isDirectory: true)
        while true {
            if fileManager.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }
}

/// Parsing git's output for worktrees (no git involved).
public enum WorktreeOutput {
    public struct ListedWorktree: Equatable, Sendable {
        public var path: String
        public var locked: Bool
    }

    /// `git worktree list --porcelain`: one block per worktree, the main working tree first.
    public static func parseList(_ text: String) -> [ListedWorktree] {
        var result: [ListedWorktree] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                result.append(ListedWorktree(path: String(line.dropFirst("worktree ".count)), locked: false))
            } else if line == "locked" || line.hasPrefix("locked ") {
                result[result.count - 1].locked = true
            }
        }
        return result
    }

    /// `git status --porcelain=v1 -z --untracked-files=all`: changed tracked files and untracked files. Works on bytes,
    /// so file names that are not UTF-8 count too.
    public static func countStatus(_ output: Data) -> (changed: Int, untracked: Int) {
        var changed = 0
        var untracked = 0
        let records = output.split(separator: 0, omittingEmptySubsequences: false)
        var index = 0
        while index < records.count {
            let record = Array(records[index])
            index += 1
            guard record.count > 3 else { continue }
            let (x, y) = (record[0], record[1])
            if x == UInt8(ascii: "?") && y == UInt8(ascii: "?") {
                untracked += 1
            } else if x == UInt8(ascii: "!") && y == UInt8(ascii: "!") {
                continue
            } else {
                changed += 1
                // A rename or copy is followed by the old path in its own record.
                if [x, y].contains(UInt8(ascii: "R")) || [x, y].contains(UInt8(ascii: "C")) { index += 1 }
            }
        }
        return (changed, untracked)
    }
}
