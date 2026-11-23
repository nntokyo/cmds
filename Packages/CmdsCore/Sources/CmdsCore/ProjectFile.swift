import CryptoKit
import Foundation

/// `.cmds.json` in a project (#174 G20): the commands that start working on it (a dev server, a test watcher) and the
/// pages to open, run with Workspace › Run Project Commands. A file nobody confirmed, or one changed since, is shown
/// in full and runs only after the user says so in the app; scripts and agents can run only a confirmed one.
///
/// ```json
/// {
///   "commands": [
///     {"title": "Dev server", "run": "npm run dev", "split": "right"},
///     {"title": "Tests", "run": "npm test -- --watch", "split": "down"}
///   ],
///   "open": ["http://localhost:5173"]
/// }
/// ```
public struct ProjectFile: Equatable, Sendable {
    public static let fileName = ".cmds.json"
    public static let maxCommands = 8
    public static let maxPages = 4
    /// Larger files are refused (it is a short list of commands).
    public static let maxBytes = 64 * 1024

    public enum Split: String, Equatable, Sendable {
        case right, down, tab
    }

    public struct Command: Equatable, Sendable {
        public var title: String
        /// Run by the pane's shell in the project folder; the shell stays when it ends.
        public var run: String
        public var split: Split

        public init(title: String, run: String, split: Split = .right) {
            self.title = title
            self.run = run
            self.split = split
        }
    }

    public struct Invalid: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    public var commands: [Command]
    public var pages: [String]
    /// The SHA-256 of the file's bytes: what the user confirmed.
    public var digest: String

    /// Parses and checks a `.cmds.json`.
    public static func parse(_ data: Data) throws -> ProjectFile {
        guard data.count <= maxBytes else { throw Invalid(description: "\(fileName) is larger than \(maxBytes / 1024) KB") }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), case .object(let object) = value else {
            throw Invalid(description: "\(fileName) is not a JSON object")
        }
        let known: Set<String> = ["commands", "open", "$schema"]
        if let unknown = object.keys.first(where: { !known.contains($0) }) {
            throw Invalid(description: "unknown key \"\(unknown)\" in \(fileName) (known: commands, open)")
        }
        var commands: [Command] = []
        for (index, entry) in (object["commands"]?.arrayValue ?? []).enumerated() {
            guard let run = entry["run"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !run.isEmpty else {
                throw Invalid(description: "commands[\(index)] needs \"run\" (the command line)")
            }
            guard !run.contains("\n") else { throw Invalid(description: "commands[\(index)].run must be one line") }
            var split = Split.right
            if let raw = entry["split"]?.stringValue {
                guard let parsed = Split(rawValue: raw) else {
                    throw Invalid(description: "commands[\(index)].split must be right, down or tab")
                }
                split = parsed
            }
            let title = entry["title"]?.stringValue?.trimmingCharacters(in: .whitespaces)
            commands.append(Command(title: title.flatMap { $0.isEmpty ? nil : String($0.prefix(60)) } ?? String(run.prefix(60)),
                                    run: run, split: split))
        }
        guard commands.count <= maxCommands else { throw Invalid(description: "at most \(maxCommands) commands") }
        var pages: [String] = []
        for (index, entry) in (object["open"]?.arrayValue ?? []).enumerated() {
            guard let page = entry.stringValue, let url = URL(string: page),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw Invalid(description: "open[\(index)] must be an http or https address")
            }
            pages.append(page)
        }
        guard pages.count <= maxPages else { throw Invalid(description: "at most \(maxPages) pages to open") }
        guard !commands.isEmpty || !pages.isEmpty else { throw Invalid(description: "\(fileName) has no commands and nothing to open") }
        return ProjectFile(commands: commands, pages: pages, digest: digest(of: data))
    }

    public static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The `.cmds.json` for `directory`: in it or a parent, up to the repository's top level (the folder with `.git`),
    /// else only `directory` itself.
    public static func find(from directory: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> String? {
        var folder = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        for _ in 0..<40 {
            let candidate = folder.appendingPathComponent(fileName).path
            if fileExists(candidate) { return candidate }
            if fileExists(folder.appendingPathComponent(".git").path) { return nil }  // the repository's top level
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { return nil }
            folder = parent
        }
        return nil
    }

    /// What will run, as shown before the first run (and by `cmds project show`).
    public var lines: [String] {
        commands.map { "\($0.title): \($0.run)  [\($0.split.rawValue)]" } + pages.map { "open \($0)" }
    }
}
