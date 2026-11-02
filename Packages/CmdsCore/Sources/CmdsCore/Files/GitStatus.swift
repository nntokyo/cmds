import Foundation

/// Git state of a row in a files pane, from `git status --porcelain=v1 -z`.
public enum GitFileState: String, Codable, Sendable, Comparable {
    case untracked = "?"
    case deleted = "D"
    case renamed = "R"
    case added = "A"
    case modified = "M"
    case conflicted = "U"

    /// For a folder with several changed files inside: the most pressing one.
    private var rank: Int {
        switch self {
        case .untracked: return 0
        case .deleted: return 1
        case .renamed: return 2
        case .added: return 3
        case .modified: return 4
        case .conflicted: return 5
        }
    }

    public static func < (a: GitFileState, b: GitFileState) -> Bool { a.rank < b.rank }
}

public enum GitStatus {
    /// Paths (relative to the repository's top level) and their state, from `git status --porcelain=v1 -z`.
    /// Untracked folders end in `/` as git prints them. Renames report the new path.
    public static func parse(_ output: Data) -> [(path: String, state: GitFileState)] {
        var result: [(String, GitFileState)] = []
        let records = output.split(separator: 0, omittingEmptySubsequences: false)
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard record.count > 3, let line = String(data: Data(record), encoding: .utf8) else { continue }
            let x = line[line.startIndex]
            let y = line[line.index(after: line.startIndex)]
            let path = String(line.dropFirst(3))
            // A rename or copy is followed by the old path in its own record.
            if x == "R" || x == "C" || y == "R" || y == "C" { index += 1 }
            guard let state = state(x: x, y: y) else { continue }
            result.append((path, state))
        }
        return result
    }

    static func state(x: Character, y: Character) -> GitFileState? {
        switch (x, y) {
        case ("?", "?"): return .untracked
        case ("!", "!"): return nil
        case ("U", _), (_, "U"), ("A", "A"), ("D", "D"): return .conflicted
        case (_, "M"), ("M", _), (_, "T"), ("T", _): return .modified
        case ("A", _): return .added
        case ("R", _), ("C", _), (_, "R"), (_, "C"): return .renamed
        case ("D", _), (_, "D"): return .deleted
        default: return nil
        }
    }

    /// From `git rev-parse --show-prefix --absolute-git-dir`: the folder's path inside the repository (`""` at the
    /// top, else ending in `/`) and the repository's git directory, which the files pane watches (its `index` and
    /// `HEAD` are replaced there by commits, staging and checkouts, #43). nil when the output is not like that.
    public static func repository(fromRevParse output: String) -> (prefix: String, gitDirectory: String)? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2, lines[1].hasPrefix("/") else { return nil }
        return (String(lines[0]), String(lines[1]))
    }

    /// The state per name of the entries of one folder. `prefix` is the folder's path inside the repository as
    /// `git rev-parse --show-prefix` prints it (`""` at the top, else ending in `/`). A folder gets the most
    /// pressing state of what changed inside it.
    public static func states(_ changes: [(path: String, state: GitFileState)], prefix: String) -> [String: GitFileState] {
        var result: [String: GitFileState] = [:]
        for change in changes where change.path.hasPrefix(prefix) {
            let rest = change.path.dropFirst(prefix.count)
            guard let name = rest.split(separator: "/", omittingEmptySubsequences: true).first else { continue }
            let key = String(name)
            if let existing = result[key], existing >= change.state { continue }
            result[key] = change.state
        }
        return result
    }
}
