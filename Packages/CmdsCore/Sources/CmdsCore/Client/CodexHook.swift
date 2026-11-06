import Foundation

/// Turns a Codex hook payload (JSON on stdin, `~/.codex/hooks.json`) into what cmds shows for the pane.
/// Used by `cmds hook codex`; see docs/guide/ai-agents.md for the hook configuration.
///
/// Codex runs hooks with its own environment, which for TUIs on the shared app-server daemon is the daemon's: the
/// pane in `CMDS_PANE_ID` may not be the one whose session fired the hook. The payload's `session_id` and `cwd` are
/// forwarded so the app can find the right pane (AppController+Agents, `codexHook`).
public enum CodexHook {
    public static let title = "Codex"

    /// What a hook event means for the pane's agent.
    public enum Event: Equatable, Sendable {
        /// `PermissionRequest`: Codex asks for approval (notifies with what it wants to do).
        case needsInput(ClaudeHook.Notification)
        /// `Stop`: the turn ended (notifies with the first line of the reply).
        case finished(ClaudeHook.Notification)
        /// `UserPromptSubmit`, `PreToolUse`, `PostToolUse`: Codex is working.
        case working
        /// `Interrupt`: the user stopped the turn; idle, nothing to notify.
        case interrupted

        public var notification: ClaudeHook.Notification? {
            switch self {
            case .needsInput(let note), .finished(let note): return note
            case .working, .interrupted: return nil
            }
        }
    }

    public struct Payload: Equatable, Sendable {
        public var eventName: String
        public var event: Event
        /// Codex's session (thread) id; nil when absent.
        public var sessionID: String?
        /// The session's working directory.
        public var cwd: String?
    }

    /// The payload of a hook input; nil for unknown events (`SessionStart`, `SessionEnd`, which Codex also sends after
    /// 30 idle minutes, …), invalid JSON and `Stop` re-entries (`stop_hook_active`).
    public static func payload(fromHookInput data: Data) -> Payload? {
        guard let input = try? JSONDecoder().decode(JSONValue.self, from: data), case .object = input,
              let name = input["hook_event_name"]?.stringValue else { return nil }
        let event: Event
        switch name {
        case "PermissionRequest":
            event = .needsInput(.init(title: title, body: TranscriptText.truncate(approvalText(input), ClaudeHook.maxBodyLength)))
        case "Stop":
            if input["stop_hook_active"]?.boolValue == true { return nil }
            let body = input["last_assistant_message"]?.stringValue.map(TranscriptText.firstLine)
                .flatMap { $0.isEmpty ? nil : $0 } ?? "Finished"
            event = .finished(.init(title: title, body: TranscriptText.truncate(body, ClaudeHook.maxBodyLength)))
        case "UserPromptSubmit", "PreToolUse", "PostToolUse":
            event = .working
        case "Interrupt":
            event = .interrupted
        default:
            return nil
        }
        return Payload(eventName: name, event: event,
                       sessionID: input["session_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                       cwd: input["cwd"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// `PermissionRequest`: Codex's own description of the action, else the command, else a generic line.
    static func approvalText(_ input: JSONValue) -> String {
        let toolInput = input["tool_input"]
        if let description = toolInput?["description"]?.stringValue.map(TranscriptText.firstLine), !description.isEmpty {
            return description
        }
        var command = toolInput?["command"]?.stringValue
        if command == nil, let parts = toolInput?["command"]?.arrayValue {
            command = parts.compactMap(\.stringValue).joined(separator: " ")
        }
        if let command = command.map(TranscriptText.firstLine), !command.isEmpty { return command }
        if let tool = input["tool_name"]?.stringValue, !tool.isEmpty { return "Approve \(tool)?" }
        return "Codex needs your approval"
    }

    /// What the CLI sends to the app (`agent.codex_hook`): the event, the session and directory, and the notification
    /// text only, never the prompt, tool input or output.
    public static func forwardedInput(_ payload: Payload) -> JSONValue {
        var object: [String: JSONValue] = ["hook_event_name": .string(payload.eventName)]
        if let id = payload.sessionID { object["session_id"] = .string(id) }
        if let cwd = payload.cwd { object["cwd"] = .string(cwd) }
        switch payload.event {
        case .needsInput(let note): object["message"] = .string(note.body)
        case .finished(let note): object["last_assistant_message"] = .string(note.body)
        case .working, .interrupted: break
        }
        return .object(object)
    }

    /// Reads a forwarded input back (the app side). `message` stands in for `PermissionRequest`'s tool input.
    public static func payload(fromForwarded input: JSONValue) -> Payload? {
        guard case .object = input, let name = input["hook_event_name"]?.stringValue else { return nil }
        var object: [String: JSONValue] = ["hook_event_name": .string(name)]
        for key in ["session_id", "cwd", "last_assistant_message"] { object[key] = input[key] }
        if let message = input["message"]?.stringValue { object["tool_input"] = .object(["description": .string(message)]) }
        guard let data = try? JSONEncoder().encode(JSONValue.object(object)) else { return nil }
        return payload(fromHookInput: data)
    }

    /// A pane that may have sent a hook event, as of the last metadata scan.
    public struct Pane: Equatable, Sendable {
        public var paneID: String
        /// Working directory of the pane's Codex process, when known.
        public var cwd: String?
        /// The Codex session matched to the pane (from its session file), nil until one is.
        public var sessionID: String?

        public init(paneID: String, cwd: String?, sessionID: String?) {
            self.paneID = paneID
            self.cwd = cwd
            self.sessionID = sessionID
        }
    }

    /// The pane a hook event belongs to, among the panes running Codex: the one whose session it is; else, for a
    /// session no pane is known to have yet (a new one), `envPane` or the only such pane in the session's directory.
    /// nil when it cannot be told (the event is dropped rather than shown on another pane).
    public static func targetPane(sessionID: String?, cwd: String?, envPane: String?, panes: [Pane]) -> String? {
        if let sessionID, let pane = panes.first(where: { $0.sessionID == sessionID }) { return pane.paneID }
        let candidates = panes.filter { $0.sessionID == nil && CodexSessionMatcher.sameDirectory($0.cwd, cwd) }
        if let envPane, candidates.contains(where: { $0.paneID == envPane }) { return envPane }
        return candidates.count == 1 ? candidates[0].paneID : nil
    }

    /// What the hook prints: Codex reads `Stop`'s stdout as JSON (plain text is an error), so it gets an empty
    /// object; other events print nothing.
    public static func standardOutput(forHookInput data: Data) -> String? {
        guard let input = try? JSONDecoder().decode(JSONValue.self, from: data),
              let name = input["hook_event_name"]?.stringValue else { return nil }
        return name == "Stop" || name == "SubagentStop" ? "{}" : nil
    }
}
