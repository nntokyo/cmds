import Foundation

/// `claude -p --output-format stream-json --include-partial-messages` read as it comes (#248): the answer is the
/// `result` line, taken as soon as it arrives (Claude Code takes about a second more to exit), and the text as it is
/// written, for speaking a detailed summary sentence by sentence. Lines of a subagent (`parent_tool_use_id`) and
/// anything else are ignored.
public enum AssistantClaudeStream {
    public enum Event: Equatable, Sendable {
        /// More text of the answer being written.
        case text(String)
        /// The model started to use a tool: the text of this turn so far was no answer ("I'll search…").
        case toolUse
        /// The model's turn ended (`end_turn`, or `tool_use` when it goes on with a tool).
        case turnEnded(String?)
        /// The final answer (nil text or `isError`: it failed).
        case result(String?, isError: Bool)
    }

    /// The events in one line of output.
    public static func events(inLine line: String) -> [Event] {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        if let parent = object["parent_tool_use_id"], !(parent is NSNull) { return [] }
        switch object["type"] as? String {
        case "result":
            let isError = (object["is_error"] as? Bool) == true || (object["subtype"] as? String) != "success"
            return [.result(object["result"] as? String, isError: isError)]
        case "stream_event":
            guard let event = object["event"] as? [String: Any] else { return [] }
            switch event["type"] as? String {
            case "content_block_start":
                let type = (event["content_block"] as? [String: Any])?["type"] as? String
                return type == "text" || type == "thinking" || type == "redacted_thinking" ? [] : [.toolUse]
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String else { return [] }
                return [.text(text)]
            case "message_delta":
                return [.turnEnded((event["delta"] as? [String: Any])?["stop_reason"] as? String)]
            default:
                return []
            }
        default:
            return []
        }
    }
}

/// The sentences of an answer as it is written (#248), made fit to speak (`AssistantWeb.speakable`: no "Sources:"
/// list, links or Markdown): each one once, when it is complete. A turn that ends in a tool use (a preamble such as
/// "I'll search for that.") is dropped. `streaming` false (calls with tools): nothing before the model's last turn
/// ends, so a preamble is never spoken.
public struct AssistantSpokenStream: Equatable, Sendable {
    public let streaming: Bool
    private var turn = ""
    private var released = 0

    public init(streaming: Bool) {
        self.streaming = streaming
    }

    /// The sentences that became complete with `event`.
    public mutating func take(_ event: AssistantClaudeStream.Event) -> [String] {
        switch event {
        case .text(let text):
            turn += text
            return streaming ? release(complete: false) : []
        case .toolUse:
            turn = ""
            released = 0
            return []
        case .turnEnded(let reason):
            guard reason != "tool_use" else {
                turn = ""
                released = 0
                return []
            }
            return release(complete: true)
        case .result:
            return []
        }
    }

    /// The sentences not released yet; the last one only when the turn is `complete` (or a line break follows it).
    private mutating func release(complete: Bool) -> [String] {
        var sentences = AssistantBrevity.sentences(AssistantWeb.speakable(turn))
        if !complete, !(turn.last?.isNewline ?? false), !sentences.isEmpty { sentences.removeLast() }
        guard sentences.count > released else { return [] }
        let new = Array(sentences[released...])
        released = sentences.count
        return new
    }
}
