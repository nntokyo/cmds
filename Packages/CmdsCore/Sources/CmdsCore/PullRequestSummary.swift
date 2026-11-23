import Foundation

/// The pull request of a workspace's branch and its checks, for the sidebar's branch line (#174 G16), from the user's
/// own GitHub CLI: `gh pr view --json number,state,isDraft,url,statusCheckRollup` in the workspace's folder.
public struct PullRequestSummary: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case open, draft, merged, closed
    }

    /// How the checks stand, most pressing first.
    public enum Checks: String, Codable, Sendable {
        case failing, pending, passing
    }

    public var number: Int
    public var state: State
    public var url: String?
    /// Checks that passed (success, neutral, skipped), failed (failure, error, cancelled, timed out…) or still run.
    public var passed: Int
    public var failed: Int
    public var pending: Int

    public init(number: Int, state: State, url: String? = nil, passed: Int = 0, failed: Int = 0, pending: Int = 0) {
        self.number = number
        self.state = state
        self.url = url
        self.passed = passed
        self.failed = failed
        self.pending = pending
    }

    /// nil without checks.
    public var checks: Checks? {
        if failed > 0 { return .failing }
        if pending > 0 { return .pending }
        return passed > 0 ? .passing : nil
    }

    /// The arguments for `gh` (run in the workspace's folder: the PR of its current branch).
    public static let ghArguments = ["pr", "view", "--json", "number,state,isDraft,url,statusCheckRollup"]

    /// Parses `gh pr view --json …`; nil when it is not that.
    public static func parse(_ data: Data) -> PullRequestSummary? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let number = value["number"]?.intValue, let rawState = value["state"]?.stringValue else { return nil }
        let state: State
        switch rawState.uppercased() {
        case "MERGED": state = .merged
        case "CLOSED": state = .closed
        default: state = value["isDraft"]?.boolValue == true ? .draft : .open
        }
        var summary = PullRequestSummary(number: number, state: state, url: value["url"]?.stringValue)
        for check in value["statusCheckRollup"]?.arrayValue ?? [] {
            switch outcome(check) {
            case .passing: summary.passed += 1
            case .failing: summary.failed += 1
            case .pending: summary.pending += 1
            }
        }
        return summary
    }

    /// A check run (`status`, `conclusion`) or a commit status (`state`).
    private static func outcome(_ check: JSONValue) -> Checks {
        if let status = check["status"]?.stringValue, !status.isEmpty {
            guard status.uppercased() == "COMPLETED" else { return .pending }
            switch (check["conclusion"]?.stringValue ?? "").uppercased() {
            case "SUCCESS", "NEUTRAL", "SKIPPED": return .passing
            case "": return .pending
            default: return .failing  // FAILURE, CANCELLED, TIMED_OUT, ACTION_REQUIRED, STARTUP_FAILURE, STALE
            }
        }
        switch (check["state"]?.stringValue ?? "").uppercased() {
        case "SUCCESS": return .passing
        case "FAILURE", "ERROR": return .failing
        default: return .pending  // PENDING, EXPECTED
        }
    }

    /// The sidebar's short form: `#405 ✓` (checks passed), `#405 ✗` (one failed), `#405 ●` (running), `#405` (none);
    /// a merged or closed PR shows its state instead of the checks.
    public var badge: String {
        switch state {
        case .merged: return "#\(number) merged"
        case .closed: return "#\(number) closed"
        case .open, .draft:
            let mark: String
            switch checks {
            case .failing: mark = " ✗"
            case .pending: mark = " ●"
            case .passing: mark = " ✓"
            case nil: mark = ""
            }
            return "#\(number)\(mark)"
        }
    }

    /// Branches a pull request is rarely made from: not asked about.
    public static func asksAbout(branch: String) -> Bool {
        !["main", "master", "develop", "trunk"].contains(branch)
    }

    /// Whether a repository's `.git/config` names a GitHub remote (only those are asked about).
    public static func hasGitHubRemote(config: String) -> Bool {
        config.split(whereSeparator: \.isNewline).contains { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            return text.hasPrefix("url") && text.contains("github.com")
        }
    }
}
