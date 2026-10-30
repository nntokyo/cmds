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

        public var notification: Notification? {
            switch self {
            case .needsInput(let note), .finished(let note): return note
            case .working, .ended: return nil
            }
        }
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
