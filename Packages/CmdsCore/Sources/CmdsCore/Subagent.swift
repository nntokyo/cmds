import Foundation

/// A Claude Code subagent (Task / Agent tool call) running inside the agent of a terminal pane. It has no terminal of
/// its own: cmds learns about it from the `SubagentStart` / `SubagentStop` hooks and, for a local pane, follows its
/// transcript (only the last tool call and token count). docs/guide/ai-agents.md "Subagents".
public struct SubagentInfo: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case running
        /// `SubagentStop` arrived; listed for a short while, then dropped.
        case done
    }

    /// Claude Code's `agent_id`.
    public var id: String
    public var workspace: String
    public var pane: String
    /// `agent_type` (`general-purpose`, `Explore`, a custom agent's name).
    public var agentType: String?
    /// The short task description given to the Agent tool (from the transcript's `.meta.json`, local panes only).
    public var description: String?
    public var state: State
    public var startedAt: Date
    public var endedAt: Date?
    /// The current action, e.g. `Read Sources/main.swift`, `Bash: swift test` (nil: thinking / no transcript).
    public var action: String?
    /// Context of its last model call (input + cache + output tokens), when the transcript has it.
    public var tokens: Int?
    /// Seconds since start (until `endedAt` once done).
    public var elapsedSeconds: Int

    public init(id: String, workspace: String, pane: String, agentType: String? = nil, description: String? = nil,
                state: State = .running, startedAt: Date, endedAt: Date? = nil, action: String? = nil,
                tokens: Int? = nil, elapsedSeconds: Int = 0) {
        self.id = id
        self.workspace = workspace
        self.pane = pane
        self.agentType = agentType
        self.description = description
        self.state = state
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.action = action
        self.tokens = tokens
        self.elapsedSeconds = elapsedSeconds
    }

    /// `general-purpose · Fix the login test` (type alone when there is no description).
    public var title: String {
        [agentType, description].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }
}

/// Result of `agent.subagents`.
public struct SubagentList: Codable, Equatable, Sendable {
    /// In sidebar order of their workspaces, then by start.
    public var subagents: [SubagentInfo]

    public init(subagents: [SubagentInfo]) { self.subagents = subagents }
}

/// Reads what cmds shows about a subagent from its Claude Code transcript
/// (`<projects>/<project>/<session>/subagents/agent-<id>.jsonl` and the `.meta.json` next to it).
/// Only the file's tail is read; only tool names, a short target and token counts leave this type — never message text.
public enum SubagentTranscript {
    public struct Activity: Equatable, Sendable {
        public var action: String?
        public var tokens: Int?
    }

    public struct Meta: Equatable, Sendable {
        public var agentType: String?
        public var description: String?
    }

    /// Longest action / description shown.
    public static let maxActionLength = 80
    public static let maxDescriptionLength = 120
    /// Maximum length of a subagent type (`agentType`).
    static let maxAgentTypeLength = 60
    /// Larger `agent-<id>.meta.json` files are not read.
    static let maxMetaBytes = 256 * 1024

    /// `agent_id` / `session_id` as Claude Code makes them (hex, uuid); anything else is refused.
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// The subagent transcript for a parent transcript `<dir>/<session>.jsonl`: `<dir>/<session>/subagents/agent-<id>.jsonl`.
    public static func path(parentTranscript: String, sessionID: String, agentID: String) -> String? {
        guard isValidID(sessionID), isValidID(agentID), !parentTranscript.isEmpty else { return nil }
        let parent = (parentTranscript as NSString).expandingTildeInPath
        guard (parent as NSString).lastPathComponent == "\(sessionID).jsonl" else { return nil }
        let dir = (parent as NSString).deletingLastPathComponent
        return "\(dir)/\(sessionID)/subagents/agent-\(agentID).jsonl"
    }

    /// Accepts only a path of the shape Claude Code uses for subagent transcripts of this agent
    /// (`…/projects/<project>/<session>/subagents/agent-<agentID>.jsonl`, absolute, no `..`); nil otherwise.
    public static func validatedPath(_ path: String, agentID: String) -> String? {
        guard isValidID(agentID), path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let parts = (path as NSString).pathComponents
        guard parts.count >= 6, !parts.contains(".."), !parts.contains("."),
              parts[parts.count - 1] == "agent-\(agentID).jsonl",
              parts[parts.count - 2] == "subagents",
              isValidID(parts[parts.count - 3]),
              parts[parts.count - 5] == "projects" else { return nil }
        return path
    }

    /// Last action and token count from the transcript's tail; nil when the file cannot be read.
    public static func activity(path: String, tailBytes: Int = 64 * 1024) -> Activity? {
        guard let lines = TranscriptText.tailLines(path: path, tailBytes: tailBytes) else { return nil }
        var activity = Activity()
        var foundAction = false
        for line in lines.reversed() {
            guard let entry = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
                  entry["type"]?.stringValue == "assistant", let message = entry["message"] else { continue }
            if activity.tokens == nil, let usage = message["usage"] {
                let total = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
                    .compactMap { usage[$0]?.intValue }.reduce(0, +)
                if total > 0 { activity.tokens = total }
            }
            if !foundAction, let parts = message["content"]?.arrayValue {
                if let tool = parts.last(where: { $0["type"]?.stringValue == "tool_use" }) {
                    activity.action = describe(tool: tool["name"]?.stringValue ?? "", input: tool["input"],
                                               cwd: entry["cwd"]?.stringValue)
                    foundAction = true
                } else if parts.contains(where: { $0["type"]?.stringValue == "text" }) {
                    foundAction = true // the latest call answered in text: no current tool
                }
            }
            if foundAction && activity.tokens != nil { break }
        }
        return activity
    }

    /// `agentType` and `description` from `agent-<id>.meta.json` next to the transcript (nothing else is read).
    public static func meta(transcriptPath: String) -> Meta? {
        guard transcriptPath.hasSuffix(".jsonl") else { return nil }
        let metaPath = String(transcriptPath.dropLast(".jsonl".count)) + ".meta.json"
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: metaPath),
              (attributes[.size] as? NSNumber)?.intValue ?? .max < maxMetaBytes,
              let data = FileManager.default.contents(atPath: metaPath),
              let object = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        let type = object["agentType"]?.stringValue.map { TranscriptText.firstLine($0, maxLength: maxAgentTypeLength) }
        let description = object["description"]?.stringValue.map { TranscriptText.firstLine($0, maxLength: maxDescriptionLength) }
        return Meta(agentType: type?.isEmpty == false ? type : nil,
                    description: description?.isEmpty == false ? description : nil)
    }

    /// `Read Sources/main.swift`, `Bash: swift test`, `Grep TODO`, `WebFetch example.com`, or the tool name alone.
    public static func describe(tool: String, input: JSONValue?, cwd: String? = nil) -> String {
        func relative(_ path: String) -> String {
            if let cwd, !cwd.isEmpty, path.hasPrefix(cwd.hasSuffix("/") ? cwd : cwd + "/") {
                return String(path.dropFirst(cwd.hasSuffix("/") ? cwd.count : cwd.count + 1))
            }
            return (path as NSString).abbreviatingWithTildeInPath
        }
        let string = { (key: String) in input?[key]?.stringValue.map(TranscriptText.firstLine).flatMap { $0.isEmpty ? nil : $0 } }
        let text: String
        switch tool {
        case "Read", "Edit", "Write", "MultiEdit":
            text = string("file_path").map { "\(tool) \(relative($0))" } ?? tool
        case "NotebookEdit":
            text = string("notebook_path").map { "\(tool) \(relative($0))" } ?? tool
        case "Bash":
            text = string("command").map { "Bash: \(redact($0))" } ?? tool
        case "Grep", "Glob":
            text = string("pattern").map { "\(tool) \($0)" } ?? tool
        case "WebFetch":
            text = string("url").flatMap { URL(string: $0)?.host }.map { "WebFetch \($0)" } ?? tool
        case "Task", "Agent":
            text = string("description").map { "\(tool): \($0)" } ?? tool
        case "":
            text = "Tool"
        default:
            text = tool // MCP and other tools: the name only (their input may be anything)
        }
        return TranscriptText.truncate(text, maxActionLength)
    }

    /// Hides values of assignments and options that look like secrets (`TOKEN=…`, `--password …`).
    static func redact(_ command: String) -> String {
        let patterns = [
            #"(?i)\b([A-Z0-9_]*(TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|AUTH)[A-Z0-9_]*)=("[^"]*"|'[^']*'|\S+)"#,
            #"(?i)(--?(token|password|passwd|secret|api-?key|auth)[= ])("[^"]*"|'[^']*'|\S+)"#,
            #"(?i)\b(authorization:\s*\w+\s+)\S+"#,
        ]
        var result = command
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            let template = index == 0 ? "$1=***" : "$1***"
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }
}
