import Foundation

/// Whether a Claude Code session's last turn was cut off, read from the end of its transcript
/// (`<config dir>/projects/*/<id>.jsonl`): used after cmds restarts to tell a resumed agent to continue (#440) when
/// the saved session does not say (saved by an older cmds, or cmds did not get to save). A turn that ended
/// (`stop_reason: end_turn`), was stopped by the user (Esc: "[Request interrupted by user]"), or was a local command
/// (`/model`, `/clear`) is not cut off; a tool call without an answer, a tool result, or a prompt without a reply is.
public enum ClaudeTurnState {
    /// Bytes read from the end of the transcript.
    public static let tailBytes = 256 * 1024

    /// The last turn was cut off; nil when the transcript has no user or assistant message to tell.
    public static func cutOff(transcriptTail data: Data) -> Bool? {
        let text = String(decoding: data, as: UTF8.self)
        // The first line may be cut by the tail read: only whole lines count.
        for line in text.split(separator: "\n").reversed() {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = entry["type"] as? String, type == "user" || type == "assistant",
                  let message = entry["message"] as? [String: Any] else { continue }
            if type == "assistant" {
                let stop = message["stop_reason"] as? String
                return !(stop == "end_turn" || stop == "stop_sequence")
            }
            if entry["isMeta"] as? Bool == true { return false }
            let content = message["content"]
            let texts: [String]
            if let string = content as? String {
                texts = [string]
            } else if let items = content as? [[String: Any]] {
                if items.contains(where: { $0["type"] as? String == "tool_result" }) { return true }
                texts = items.compactMap { $0["text"] as? String }
            } else {
                continue
            }
            let joined = texts.joined(separator: "\n")
            if joined.contains("[Request interrupted by user") { return false }
            if joined.contains("<command-name>") || joined.contains("<local-command-stdout>") { return false }
            return true  // a prompt without a reply
        }
        return nil
    }

    /// The session's transcript in `configDir` (default `~/.claude`), if it is there.
    public static func transcriptPath(sessionID: String, configDir: String?, home: String = NSHomeDirectory(),
                                      fileManager: FileManager = .default) -> String? {
        guard AgentResume.isValidSessionID(sessionID) else { return nil }
        let projects = ClaudeSessionSharing.projectsPath(configDir ?? "~/.claude", home: home) as NSString
        guard let folders = try? fileManager.contentsOfDirectory(atPath: projects as String) else { return nil }
        return folders.lazy.map { (projects.appendingPathComponent($0) as NSString).appendingPathComponent("\(sessionID).jsonl") }
            .first { fileManager.fileExists(atPath: $0) }
    }

    /// Reads the session's transcript in `configDir` (default `~/.claude`): nil when it cannot be found or told.
    public static func cutOff(sessionID: String, configDir: String?, home: String = NSHomeDirectory(),
                              fileManager: FileManager = .default) -> Bool? {
        guard let path = transcriptPath(sessionID: sessionID, configDir: configDir, home: home, fileManager: fileManager),
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        return cutOff(transcriptTail: handle.readDataToEndOfFile())
    }
}
