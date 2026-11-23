import Foundation

/// A repository's state for the sidebar's branch line (#174 G16): uncommitted changes and commits ahead / behind the
/// upstream, from `git status --porcelain=v2 --branch -z`.
public struct GitSummary: Codable, Equatable, Sendable {
    /// Changed, staged, untracked or conflicted paths (each counted once).
    public var changes: Int
    /// Commits not on the upstream / on it but not here; nil without an upstream.
    public var ahead: Int?
    public var behind: Int?
    /// `origin/main`; nil without one.
    public var upstream: String?

    public init(changes: Int, ahead: Int? = nil, behind: Int? = nil, upstream: String? = nil) {
        self.changes = changes
        self.ahead = ahead
        self.behind = behind
        self.upstream = upstream
    }

    /// The arguments for `git` (with `-C <folder>` before them).
    public static let statusArguments = ["--no-optional-locks", "status", "--porcelain=v2", "--branch", "-z",
                                         "--untracked-files=normal"]

    /// Parses the output of `statusArguments`; nil when it is not that format.
    public static func parse(_ output: Data) -> GitSummary? {
        let fields = output.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        var summary = GitSummary(changes: 0)
        var sawBranch = false
        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            if field.hasPrefix("# ") {
                sawBranch = true
                if field.hasPrefix("# branch.upstream ") {
                    summary.upstream = String(field.dropFirst("# branch.upstream ".count))
                } else if field.hasPrefix("# branch.ab ") {
                    let parts = field.dropFirst("# branch.ab ".count).split(separator: " ")
                    if parts.count == 2, let ahead = Int(parts[0].dropFirst()), let behind = Int(parts[1].dropFirst()) {
                        summary.ahead = ahead
                        summary.behind = behind
                    }
                }
                continue
            }
            switch field.first {
            case "1", "u", "?":
                summary.changes += 1
            case "2":
                summary.changes += 1
                index += 1  // a rename or copy: the original path follows as its own field
            default:
                continue  // "!" ignored files, or something new
            }
        }
        return sawBranch ? summary : nil
    }

    /// The sidebar's short form after the branch: `±3 ↑1 ↓2` (zero parts left out; empty when clean and in step).
    public var badge: String {
        var parts: [String] = []
        if changes > 0 { parts.append("±\(changes)") }
        if let ahead, ahead > 0 { parts.append("↑\(ahead)") }
        if let behind, behind > 0 { parts.append("↓\(behind)") }
        return parts.joined(separator: " ")
    }
}
