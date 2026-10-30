import Foundation

/// Helpers for reading agent JSONL transcripts and shortening their text (`ClaudeHook`, `SubagentTranscript`).
enum TranscriptText {
    /// The lines of the file's last `tailBytes` bytes; nil when the file cannot be read. When the tail does not start
    /// at the beginning of the file, its first line is dropped (probably cut mid-line).
    static func tailLines(path: String, tailBytes: Int) -> [Data.SubSequence]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        var lines = data.split(separator: 0x0A)
        if offset > 0, !lines.isEmpty { lines.removeFirst() } // probably cut mid-line
        return lines
    }

    /// The first non-blank line, trimmed of spaces and tabs ("" when there is none).
    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// The first non-blank line of `text`, truncated to `length` characters.
    static func firstLine(_ text: String, maxLength length: Int) -> String {
        truncate(firstLine(text), length)
    }

    /// `text`, or its first `length - 1` characters and "…".
    static func truncate(_ text: String, _ length: Int) -> String {
        text.count <= length ? text : String(text.prefix(length - 1)) + "…"
    }
}
