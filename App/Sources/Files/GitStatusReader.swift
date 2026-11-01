import Foundation
import CmdsCore

/// Git state of a folder's entries for the files pane, from `git status` (run off the main thread).
///
/// Only folders inside a repository (a `.git` above them, `GitInfo`) run git at all. git runs with
/// `--no-optional-locks`, so it never takes the index lock from the user's own git commands, and is given up after a
/// few seconds in very large repositories. `/usr/bin/git` is used only when developer tools are installed (otherwise
/// it would ask to install them).
enum GitStatusReader {
    static let timeout: TimeInterval = 4

    /// Per entry name; nil outside a repository or when git is missing or too slow.
    static func states(folder: String) -> [String: GitFileState]? {
        guard GitInfo.branch(at: folder) != nil, let git = gitPath else { return nil }
        guard let prefixData = run(git, ["-C", folder, "rev-parse", "--show-prefix"]),
              let prefix = String(data: prefixData, encoding: .utf8)?.trimmingCharacters(in: .newlines) else { return nil }
        guard let output = run(git, ["--no-optional-locks", "-C", folder, "status", "--porcelain=v1", "-z",
                                     "--untracked-files=normal", "--", "."]) else { return nil }
        return GitStatus.states(GitStatus.parse(output), prefix: prefix)
    }

    private static let gitPath: String? = {
        let fileManager = FileManager.default
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fileManager.isExecutableFile(atPath: path) {
            return path
        }
        // The /usr/bin shim needs the Command Line Tools or Xcode (else it offers to install them).
        let developerTools = ["/Library/Developer/CommandLineTools/usr/bin/git",
                              "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
        return developerTools.contains(where: fileManager.isExecutableFile(atPath:)) ? "/usr/bin/git" : nil
    }()

    /// stdout of a successful run; nil on failure or timeout.
    private static func run(_ executable: String, _ arguments: [String]) -> Data? {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        return CommandOutput.run(executable, arguments, environment: environment, timeout: timeout)
    }
}
