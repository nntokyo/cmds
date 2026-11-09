import CmdsCore
import Foundation

/// Worktree workspaces (docs/guide/workspaces-and-panes.md "Worktree workspaces"): `cmds new --worktree`,
/// `cmds changes`, `cmds close --remove-worktree`.
extension CLI {
    /// Params of `workspace.create` for a local `cmds new` (with or without `--worktree`). Relative `--cwd` / `--path`
    /// are resolved against `currentDirectory`.
    static func newWorkspaceParams(_ args: Arguments, currentDirectory: String) throws -> [String: JSONValue?] {
        func absolute(_ path: String) -> String {
            let expanded = (path as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
            return ((currentDirectory as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
        }
        var params: [String: JSONValue?] = [
            "title": args[option: "title"].json,
            "cwd": .string(absolute(args[option: "cwd"] ?? currentDirectory)),
            "command": shellCommand(args.rest ?? []).json,
            "account": args[option: "account"].json,
        ]
        guard let branch = args[option: "worktree"] else {
            if args[option: "base"] != nil || args[option: "path"] != nil {
                throw CLIError.usage("--base and --path go with --worktree")
            }
            return params
        }
        guard !branch.trimmingCharacters(in: .whitespaces).isEmpty else { throw CLIError.usage("--worktree needs a branch name") }
        params["worktree"] = .string(branch)
        params["base"] = args[option: "base"].json
        params["worktreePath"] = args[option: "path"].map { .string(absolute($0)) }
        return params
    }

    /// Prints the warning a result may carry (`git fetch` failed) on stderr.
    static func printWarning(of result: JSONValue) {
        if let warning = result["warning"]?.stringValue { printError("warning: \(warning)") }
    }

    static let changesCommand = Command(
        name: "changes", usage: "changes [workspace]",
        summary: "Show what a workspace's branch changed (default: the current workspace) in a diff preview.",
        details: """
            Same as Show Changes in the workspace's sidebar menu: the commits since the base, then one diff from where
            the branch left the base to the working tree (committed, staged and unstaged changes and untracked files).
            The base is the one the worktree was created from (`cmds new --worktree`), else the repository's default
            branch (the remote's HEAD, else main or master). Nothing is fetched. The diff opens in the workspace's
            preview pane, else in a new one to the right (the keyboard stays where it is). Prints the preview pane id.
            """) { ctx in
        try ctx.args.expectPositionals(0...1, usage: "cmds changes [workspace]")
        let id = try ctx.args.positionals.first.map { try resolveWorkspace(ctx, $0) } ?? ctx.envWorkspace
        let result = try ctx.call("workspace.changes", ["id": id.json], timeout: 120)
        ctx.printResult(result, field: "pane")
    }
}
