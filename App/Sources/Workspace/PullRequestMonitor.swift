import Foundation
import CmdsCore

/// The pull request of each local workspace's branch and its checks (#174 G16), from the user's own GitHub CLI.
///
/// Asked only for branches a PR is made from (`PullRequestSummary.asksAbout`) in repositories with a GitHub remote,
/// while the sidebar shows the branch line and the pull request; at most every `interval` per branch, at most
/// `parallel` `gh` runs at a time on a background queue (never in the 2 s metadata scan), each given up after
/// `timeout`; after a failure (not signed in, offline) that branch rests for `backoff`. Nothing runs without `gh`.
@MainActor
final class PullRequestMonitor {
    static let interval: TimeInterval = 120
    static let backoff: TimeInterval = 600
    static let timeout: TimeInterval = 15
    static let parallel = 2

    /// `gh` where Homebrew and the installer put it (an app does not get the shell's PATH).
    static let ghPath: String? = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private struct Entry {
        var summary: PullRequestSummary?
        var fetchedAt = Date.distantPast
        var restUntil: Date?
        var running = false
    }

    private weak var controller: AppController?
    private let queue = DispatchQueue(label: "cmds.pull-requests", qos: .utility, attributes: .concurrent)
    /// By `worktree|branch`.
    private var entries: [String: Entry] = [:]
    /// Whether a repository (its project root) has a GitHub remote, read once per run.
    private var gitHubRepositories: [String: Bool] = [:]

    init(controller: AppController) {
        self.controller = controller
    }

    /// After each metadata scan: shows what is known and asks `gh` for what is due.
    func update(_ workspaces: [Workspace], now: Date = Date()) {
        let enabled = Self.ghPath != nil && AppSettings.shared.sidebar(.branch) && AppSettings.shared.sidebar(.pullRequest)
        var wanted: Set<String> = []
        for workspace in workspaces {
            guard enabled, let key = key(for: workspace), let worktree = key.split(separator: "|").first.map(String.init) else {
                set(nil, on: workspace)
                continue
            }
            wanted.insert(key)
            let entry = entries[key] ?? Entry()
            entries[key] = entry
            set(entry.summary, on: workspace)
            let resting = entry.restUntil.map { now < $0 } ?? false
            if !entry.running, !resting, now.timeIntervalSince(entry.fetchedAt) >= Self.interval,
               entries.values.filter(\.running).count < Self.parallel {
                fetch(key, in: worktree)
            }
        }
        entries = entries.filter { wanted.contains($0.key) || $0.value.running }
    }

    /// `worktree|branch` of a local workspace on a branch a PR may come from, in a GitHub repository.
    private func key(for workspace: Workspace) -> String? {
        guard !workspace.isRemote, let directory = workspace.workingDirectory, let branch = workspace.gitBranch,
              PullRequestSummary.asksAbout(branch: branch), let worktree = GitInfo.worktreeRoot(at: directory),
              let project = GitInfo.projectRoot(at: directory) else { return nil }
        let isGitHub = gitHubRepositories[project] ?? {
            let config = (try? String(contentsOfFile: project + "/.git/config", encoding: .utf8)) ?? ""
            let found = PullRequestSummary.hasGitHubRemote(config: config)
            gitHubRepositories[project] = found
            return found
        }()
        return isGitHub ? "\(worktree)|\(branch)" : nil
    }

    private func set(_ summary: PullRequestSummary?, on workspace: Workspace) {
        guard workspace.pullRequest != summary else { return }
        workspace.pullRequest = summary
        controller?.emit(.workspace(id: workspace.id))
    }

    private func fetch(_ key: String, in worktree: String) {
        guard let gh = Self.ghPath else { return }
        entries[key]?.running = true
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["NO_COLOR"] = "1"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        queue.async { [weak self] in
            let completion = CommandOutput.complete(gh, PullRequestSummary.ghArguments, environment: environment,
                                                    directory: worktree, timeout: Self.timeout)
            let stderr = completion.map { String(decoding: $0.stderr, as: UTF8.self) } ?? ""
            // A branch without a PR is an answer too (gh exits 1 saying so); anything else is a failure.
            let noPullRequest = completion?.status != 0 && stderr.contains("no pull requests found")
            let summary = completion.flatMap { $0.status == 0 ? PullRequestSummary.parse($0.stdout) : nil }
            let succeeded = summary != nil || noPullRequest
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, var entry = self.entries[key] else { return }
                    entry.running = false
                    entry.fetchedAt = Date()
                    if succeeded {
                        entry.summary = summary
                        entry.restUntil = nil
                    } else {
                        entry.restUntil = Date().addingTimeInterval(Self.backoff)
                    }
                    self.entries[key] = entry
                    if let controller = self.controller { self.update(controller.workspaces) }
                }
            }
        }
    }

    #if DEBUG
    /// `debug.pull_requests`: what each key last got and whether it rests.
    var debugState: JSONValue {
        .object(Dictionary(uniqueKeysWithValues: entries.map { key, entry in
            (key, JSONValue.object([
                "badge": entry.summary.map { .string($0.badge) } ?? .null,
                "running": .bool(entry.running),
                "resting": .bool(entry.restUntil.map { Date() < $0 } ?? false),
            ]))
        }))
    }
    #endif
}
