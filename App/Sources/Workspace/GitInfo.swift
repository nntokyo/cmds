import Foundation

/// Reads the current git branch straight from `.git/HEAD` (no `git` process).
enum GitInfo {
    /// Branch name, short commit hash when detached, or nil outside a repository.
    /// Handles worktrees and submodules, where `.git` is a file containing `gitdir: <path>`.
    static func branch(at path: String) -> String? {
        let fileManager = FileManager.default
        var directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        while true {
            let dotGit = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                guard let gitDir = isDirectory.boolValue ? dotGit : resolveGitFile(dotGit, base: directory) else { return nil }
                return headName(gitDir: gitDir)
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
    }

    /// The project a directory belongs to: the repository's top level (a linked worktree counts as its main
    /// repository), or nil outside a repository. Reads only `.git` entries (sidebar grouping).
    static func projectRoot(at path: String) -> String? {
        let fileManager = FileManager.default
        var directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        while true {
            let dotGit = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if !isDirectory.boolValue, let gitDir = resolveGitFile(dotGit, base: directory),
                   let range = gitDir.path.range(of: "/.git/worktrees/") {
                    return String(gitDir.path[..<range.lowerBound])
                }
                return directory.path
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
    }

    private static func resolveGitFile(_ file: URL, base: URL) -> URL? {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in contents.split(whereSeparator: \.isNewline) where line.hasPrefix("gitdir:") {
            let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            return path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path).standardizedFileURL
        }
        return nil
    }

    private static func headName(gitDir: URL) -> String? {
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref:") {
            let ref = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
        }
        return trimmed.isEmpty ? nil : String(trimmed.prefix(7))
    }
}
