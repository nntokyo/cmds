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

    /// The state per entry name, and the repository's git directory (the files pane watches it, #43).
    struct Result: Equatable {
        var states: [String: GitFileState]
        var gitDirectory: String
    }

    /// nil outside a repository or when git is missing or too slow.
    static func read(folder: String) -> Result? {
        guard GitInfo.branch(at: folder) != nil, let git = gitPath else { return nil }
        guard let revParse = run(git, ["-C", folder, "rev-parse", "--show-prefix", "--absolute-git-dir"]),
              let repository = GitStatus.repository(fromRevParse: String(decoding: revParse, as: UTF8.self)) else { return nil }
        guard let output = run(git, ["--no-optional-locks", "-C", folder, "status", "--porcelain=v1", "-z",
                                     "--untracked-files=normal", "--", "."]) else { return nil }
        return Result(states: GitStatus.states(GitStatus.parse(output), prefix: repository.prefix),
                      gitDirectory: repository.gitDirectory)
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
