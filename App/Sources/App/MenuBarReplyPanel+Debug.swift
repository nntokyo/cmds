#if DEBUG
import AppKit
import CmdsCore

/// Tests only (`debug.menubar_reply`, docs/internals/testing.md): the menu bar's reply panel (#213) without UI
/// scripting. It never takes the keyboard here, so a test instance does not take it from the app in use.
extension MenuBarReplyPanel {
    /// `action`: `open` (default; `workspace` id, as choosing it in the menu does), `state`, `pick` (`number`, as the
    /// button or 1–9), `reply` (`text`, as Return in the reply field), `key` (`key`: escape, up, down, enter,
    /// interrupt — the key bar), `next` / `previous` (⌘↓ / ⌘↑), `openInCmds` (⌘↩), `close`.
    /// Returns whether it is open, its workspace and pane, the header lines, a note (pane or workspace closed), the
    /// mirror's text, the parsed question and options, its window number (`screencapture -l`) and frame; `snapshot`
    /// adds a picture of its content (`png_base64`; without the window's translucency).
    static func debugPerform(_ params: JSONValue?, controller: AppController) throws -> JSONValue {
        let action = params?["action"]?.stringValue ?? "open"
        if action != "open", action != "state", action != "close", current == nil {
            throw RPCError.invalidParams("the reply panel is not open")
        }
        switch action {
        case "open":
            guard let id = params?["workspace"]?.stringValue else { throw RPCError.invalidParams("workspace is required") }
            guard let item = MenuBarStatusItem.shared else { throw RPCError.invalidParams("no menu bar item") }
            guard item.presentReply(workspaceID: id, takeKeyboard: false) != nil else {
                throw RPCError.notFound("no workspace \(id)")
            }
        case "state":
            current?.refresh()
        case "pick":
            guard let number = params?["number"]?.intValue else { throw RPCError.invalidParams("number is required") }
            current?.pick(number)
        case "reply":
            current?.reply(params?["text"]?.stringValue ?? "")
        case "key":
            let names: [String: ReplyKey] = ["escape": .escape, "up": .up, "down": .down, "enter": .enter,
                                             "interrupt": .interrupt]
            guard let key = params?["key"]?.stringValue.flatMap({ names[$0] }) else {
                throw RPCError.invalidParams("key must be one of \(names.keys.sorted().joined(separator: ", "))")
            }
            current?.send(key)
        case "next", "previous":
            current?.move(action == "next" ? 1 : -1)
        case "openInCmds":
            current?.debugOpenInCmds()
        case "close":
            current?.close()
        default:
            throw RPCError.invalidParams("unknown action \(action)")
        }
        guard let panel = current else { return .object(["open": .bool(false)]) }
        var state: [String: JSONValue] = [
            "open": .bool(true),
            "workspace": .string(panel.workspaceID),
            "pane": panel.paneID.map(JSONValue.string) ?? .null,
            "header": .array(panel.debugHeader.map(JSONValue.string)),
            "note": panel.debugNote.map(JSONValue.string) ?? .null,
            "mirror": .string(panel.debugMirrorText),
            "question": panel.prompt?.question.map(JSONValue.string) ?? .null,
            "options": .array((panel.prompt?.options ?? []).map { option in
                .object(["number": .number(Double(option.number)), "label": .string(option.label),
                         "selected": .bool(option.selected)])
            }),
            "window": .number(Double(panel.debugPanel.windowNumber)),
            "isKey": .bool(panel.debugPanel.isKeyWindow),
            "fieldEnabled": .bool(panel.debugField.isEnabled),
        ]
        let frame = panel.debugPanel.frame
        state["frame"] = .array([frame.minX, frame.minY, frame.width, frame.height].map { .number(Double($0)) })
        if params?["snapshot"]?.boolValue == true, let view = panel.debugPanel.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            state["png_base64"] = rep.representation(using: .png, properties: [:]).map { .string($0.base64EncodedString()) } ?? .null
        }
        return .object(state)
    }
}
#endif
