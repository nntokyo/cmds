import Foundation

/// Turns a Claude Code hook payload (JSON on stdin) into a cmds notification.
/// Used by `cmds hook claude`; see docs/guide/ai-agents.md for the hook configuration.
public enum ClaudeHook {
    public struct Notification: Equatable, Sendable {
        public var title: String?
        public var body: String
    }

    /// Maximum length of the body shown in the sidebar / notification.
    public static let maxBodyLength = 200

    /// What a hook event means for the pane's agent.
    public enum Event: Equatable, Sendable {
        /// `Notification`: permission prompt or waiting for input (notifies).
        case needsInput(Notification)
        /// `Stop`: the turn ended (notifies with the first line of the reply).
        case finished(Notification)
        /// `UserPromptSubmit`, `PreToolUse`, `PostToolUse`: the agent is working again (clears a stale notification).
        case working
        /// `SessionEnd`: Claude Code exits.
        case ended
        /// `SubagentStart` / `SubagentStop`: a subagent (Agent tool call) of this pane's agent started or finished.
        /// Does not change the pane's own state (a background subagent may outlive the turn).
        case subagent(Subagent)

        public var notification: Notification? {
            switch self {
            case .needsInput(let note), .finished(let note): return note
            case .working, .ended, .subagent: return nil
            }
        }
    }

    /// A `SubagentStart` / `SubagentStop` payload (`agent_id` is required; the rest degrades to nil).
    public struct Subagent: Equatable, Sendable {
        public var started: Bool
        public var agentID: String
        public var agentType: String?
        /// The subagent's transcript: `agent_transcript_path` (SubagentStop), else derived from the parent's
        /// `transcript_path` and `session_id` (SubagentStart has no path of its own). Shape-checked only
        /// (`SubagentTranscript.validatedPath`).
        public var transcriptPath: String?
    }

    /// Returns nil for events that should not notify (anything but `Notification` / `Stop`, or `Stop` re-entries).
    public static func notification(fromHookInput data: Data, readTranscript: Bool = true) -> Notification? {
        event(fromHookInput: data, readTranscript: readTranscript)?.notification
    }

    /// The event of a hook payload; nil for unknown events, invalid JSON and `Stop` re-entries (`stop_hook_active`).
    public static func event(fromHookInput data: Data, readTranscript: Bool = true) -> Event? {
        guard let input = try? JSONDecoder().decode(JSONValue.self, from: data), case .object = input else { return nil }
        let event = input["hook_event_name"]?.stringValue ?? ""
        let title = input["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Claude Code"
        switch event {
        case "Notification":
            let message = input["message"]?.stringValue ?? "Claude Code needs your attention"
            return .needsInput(Notification(title: title, body: truncate(message)))
        case "Stop":
            if input["stop_hook_active"]?.boolValue == true { return nil }
            var summary = input["last_assistant_message"]?.stringValue
            if summary == nil, readTranscript, let path = input["transcript_path"]?.stringValue {
                summary = lastAssistantText(transcriptPath: (path as NSString).expandingTildeInPath)
            }
            let body = summary.map(firstLine).flatMap { $0.isEmpty ? nil : $0 } ?? "Finished"
            return .finished(Notification(title: title, body: truncate(body)))
        case "UserPromptSubmit", "PreToolUse", "PostToolUse":
            return .working
        case "SessionEnd":
            return .ended
        case "SubagentStart", "SubagentStop":
            guard let id = input["agent_id"]?.stringValue, SubagentTranscript.isValidID(id) else { return nil }
            let type = input["agent_type"]?.stringValue.map { SubagentTranscript.truncate(SubagentTranscript.oneLine($0), 60) }
            var path = input["agent_transcript_path"]?.stringValue
                .flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
            if path == nil, let parent = input["transcript_path"]?.stringValue, let session = input["session_id"]?.stringValue {
                path = SubagentTranscript.path(parentTranscript: parent, sessionID: session, agentID: id)
            }
            return .subagent(Subagent(started: event == "SubagentStart", agentID: id,
                                      agentType: type?.isEmpty == false ? type : nil,
                                      transcriptPath: path.flatMap { SubagentTranscript.validatedPath($0, agentID: id) }))
        default:
            return nil
        }
    }

    /// The payload the CLI sends to the app (`agent.claude_hook`): only the fields the app uses, with `Stop`'s summary
    /// already taken from the transcript (the app never reads files named in a payload).
    public static func forwardedInput(fromHookInput data: Data, event: Event) -> JSONValue {
        let input = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .object([:])
        var object: [String: JSONValue] = [:]
        if let name = input["hook_event_name"]?.stringValue { object["hook_event_name"] = .string(name) }
        switch event {
        case .needsInput(let note):
            if let title = note.title { object["title"] = .string(title) }
            object["message"] = .string(note.body)
        case .finished(let note):
            if let title = note.title { object["title"] = .string(title) }
            object["last_assistant_message"] = .string(note.body)
        case .subagent(let agent):
            // Ids, type and transcript path only: never the subagent's prompt or its last message.
            object["agent_id"] = .string(agent.agentID)
            if let type = agent.agentType { object["agent_type"] = .string(type) }
            if let path = agent.transcriptPath { object["agent_transcript_path"] = .string(path) }
        case .working, .ended:
            break
        }
        return .object(object)
    }

    /// Text of the last assistant message in a Claude Code JSONL transcript (reads only the file's tail).
    public static func lastAssistantText(transcriptPath: String, tailBytes: Int = 256 * 1024) -> String? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        var lines = data.split(separator: 0x0A)
        if offset > 0, !lines.isEmpty { lines.removeFirst() } // probably cut mid-line
        for line in lines.reversed() {
            guard let entry = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
                  entry["type"]?.stringValue == "assistant", let message = entry["message"] else { continue }
            if let text = message["content"]?.stringValue, !text.isEmpty { return text }
            let texts = (message["content"]?.arrayValue ?? []).compactMap { part -> String? in
                part["type"]?.stringValue == "text" ? part["text"]?.stringValue : nil
            }
            let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { return joined }
        }
        return nil
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    private static func truncate(_ text: String) -> String {
        text.count <= maxBodyLength ? text : String(text.prefix(maxBodyLength - 1)) + "…"
    }
}
