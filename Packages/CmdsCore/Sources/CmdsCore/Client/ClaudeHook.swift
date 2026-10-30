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

    /// Returns nil for events that should not notify (anything but `Notification` / `Stop`, or `Stop` re-entries).
    public static func notification(fromHookInput data: Data, readTranscript: Bool = true) -> Notification? {
        guard let input = try? JSONDecoder().decode(JSONValue.self, from: data), case .object = input else { return nil }
        let event = input["hook_event_name"]?.stringValue ?? ""
        let title = input["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Claude Code"
        switch event {
        case "Notification":
            let message = input["message"]?.stringValue ?? "Claude Code needs your attention"
            return Notification(title: title, body: truncate(message))
        case "Stop":
            if input["stop_hook_active"]?.boolValue == true { return nil }
            var summary = input["last_assistant_message"]?.stringValue
            if summary == nil, readTranscript, let path = input["transcript_path"]?.stringValue {
                summary = lastAssistantText(transcriptPath: (path as NSString).expandingTildeInPath)
            }
            let body = summary.map(firstLine).flatMap { $0.isEmpty ? nil : $0 } ?? "Finished"
            return Notification(title: title, body: truncate(body))
        default:
            return nil
        }
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
