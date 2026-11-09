#if os(macOS)
import Foundation

/// Runs `git` for worktree workspaces (`Worktrees`) and the files pane (GitStatusReader). Blocking: call it off the
/// main thread.
///
/// git never prompts (stdin is /dev/null, `GIT_TERMINAL_PROMPT=0`) and never takes optional locks
/// (`GIT_OPTIONAL_LOCKS=0`), so it does not get in the way of the user's own git commands. `/usr/bin/git` is used only
/// when developer tools are installed (otherwise it would offer to install them).
public enum Git {
    /// Seconds a git command may take before it is stopped; `fetchTimeout` for commands that use the network.
    public static let timeout: TimeInterval = 30
    public static let fetchTimeout: TimeInterval = 90

    public static let executable: String? = {
        let fileManager = FileManager.default
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fileManager.isExecutableFile(atPath: path) {
            return path
        }
        // The /usr/bin shim needs the Command Line Tools or Xcode (else it offers to install them).
        let developerTools = ["/Library/Developer/CommandLineTools/usr/bin/git",
                              "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
        return developerTools.contains(where: fileManager.isExecutableFile(atPath:)) ? "/usr/bin/git" : nil
    }()

    /// How a git command ended.
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: String

        public var succeeded: Bool { status == 0 }
        /// stdout as text without the trailing newline.
        public var text: String { String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .newlines) }
        /// The last non-empty line of stderr (git's error), or "exit status N".
        public var message: String {
            stderr.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) }
                ?? "exit status \(status)"
        }
    }

    /// Runs `git -C directory arguments…`. Throws `WorktreeError.gitMissing` without git and `.gitFailed` when it
    /// cannot start or takes longer than `timeout`; a non-zero exit is returned, not thrown.
    public static func run(_ arguments: [String], in directory: String, timeout: TimeInterval = timeout) throws -> Output {
        guard let executable else { throw WorktreeError.gitMissing }
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // Messages are parsed and shown as they are: keep them in English whatever the user's locale.
        environment["LC_ALL"] = "C"
        guard let completion = CommandOutput.complete(executable, ["-C", directory] + arguments, environment: environment,
                                                      timeout: timeout) else {
            throw failure(arguments, "did not finish in time")
        }
        return Output(status: completion.status, stdout: completion.stdout,
                      stderr: String(decoding: completion.stderr, as: UTF8.self))
    }

    /// stdout of a command that must succeed; throws `.gitFailed` with git's message otherwise.
    @discardableResult
    public static func check(_ arguments: [String], in directory: String, timeout: TimeInterval = timeout) throws -> String {
        try checkedOutput(arguments, in: directory, timeout: timeout).text
    }

    /// The output of a command that must succeed (for its raw stdout); throws `.gitFailed` with git's message otherwise.
    public static func checkedOutput(_ arguments: [String], in directory: String, timeout: TimeInterval = timeout) throws -> Output {
        let output = try run(arguments, in: directory, timeout: timeout)
        guard output.succeeded else { throw failure(arguments, output.message) }
        return output
    }

    /// `.gitFailed` naming the git subcommand (`git diff failed: …`).
    private static func failure(_ arguments: [String], _ message: String) -> WorktreeError {
        .gitFailed(command: "git " + (arguments.first ?? ""), message: message)
    }

    /// `ref` (`refs/heads/main`, `refs/remotes/origin/main`) exists.
    static func refExists(_ ref: String, in directory: String) throws -> Bool {
        try run(["show-ref", "--verify", "--quiet", ref], in: directory).succeeded
    }

    /// `name` (branch, tag, commit) names a commit.
    static func isCommit(_ name: String, in directory: String) throws -> Bool {
        try run(["rev-parse", "--verify", "--quiet", name + "^{commit}"], in: directory).succeeded
    }

    /// The branch checked out in `directory`'s working tree; nil when HEAD is detached.
    static func currentBranch(in directory: String) throws -> String? {
        let head = try run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: directory)
        return head.succeeded && !head.text.isEmpty ? head.text : nil
    }
}
#endif
