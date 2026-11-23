import Foundation

/// Runs the CLI of the app that opened the terminal when another `cmds` was started (`CmdsEnv.cliPath`).
///
/// Terminals get the app's bundled `bin` first on `PATH`, but login shells run `path_helper`, which puts the system
/// paths, `/usr/local/bin` among them, ahead of it. So `cmds` there is the installed one, a link into
/// `/Applications/cmds.app`, even when the terminal belongs to another copy of the app (a newer download, a Debug
/// build): its hooks, MCP tools and commands could miss what that app has, or not know its replies.
public enum CLIHandoff {
    /// The CLI to run instead of this one: `CMDS_CLI_PATH` when it is an executable file other than this one (both
    /// with symbolic links resolved), and no handoff happened yet. nil: this CLI goes on.
    public static func target(environment: [String: String], ownPath: String?,
                              isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                              resolve: (String) -> String = resolvedPath) -> String? {
        guard environment[CmdsEnv.cliHandoff] == nil,
              let wanted = environment[CmdsEnv.cliPath], wanted.hasPrefix("/"),
              let ownPath, isExecutable(wanted) else { return nil }
        return resolve(wanted) == resolve(ownPath) ? nil : wanted
    }

    /// `path` with symbolic links resolved (itself when it cannot be).
    public static func resolvedPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    #if os(macOS)
    /// This process's executable as it was started (may be a symbolic link).
    public static func executablePath() -> String? {
        var size = UInt32(0)
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Replaces this process with `target`, with the same arguments and `CMDS_CLI_HANDOFF=1`. Returns only when that
    /// fails (this CLI then goes on).
    public static func run(_ target: String, arguments: [String]) {
        setenv(CmdsEnv.cliHandoff, "1", 1)
        let argv = ([target] + arguments).map { strdup($0) } + [nil]
        execv(target, argv)
        for pointer in argv { free(pointer) }
        unsetenv(CmdsEnv.cliHandoff)
    }
    #endif
}
