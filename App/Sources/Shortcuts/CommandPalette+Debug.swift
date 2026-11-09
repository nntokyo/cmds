#if DEBUG
import AppKit
import CmdsCore

/// Tests only (`debug.palette`, docs/internals/testing.md): the command palette without UI scripting.
extension CommandPalette {
    /// `open` (default: opens it over the main window, as ⇧⌘P does, unless it is open), `query` (text) filters,
    /// `move` (rows, as ↑/↓), `run` (a result index, default the selected row; runs it as Return does), `close`.
    /// Returns whether it is open, its results (kind, title, detail, shortcut, score), the selected row, the selected
    /// workspace and focused pane.
    static func debugPerform(_ params: JSONValue?, controller: AppController) throws -> JSONValue {
        let action = params?["action"]?.stringValue ?? "open"
        switch action {
        case "open":
            if current == nil { present(controller: controller, over: controller.window) }
        case "close":
            current?.close()
        case "run":
            guard let palette = current else { throw RPCError.invalidParams("the palette is not open") }
            palette.run(params?["index"]?.intValue)
        case "state":
            break
        default:
            throw RPCError.invalidParams("unknown action \(action)")
        }
        if let query = params?["query"]?.stringValue, action != "run" { current?.query = query }
        if let rows = params?["move"]?.intValue, action != "run" { current?.debugMove(rows) }
        var state: [String: JSONValue] = [
            "open": .bool(current != nil),
            "selectedWorkspace": controller.selectedWorkspaceID.map(JSONValue.string) ?? .null,
            "focusedPane": controller.focusedPane.map { .string($0.id) } ?? .null,
        ]
        if let palette = current {
            state["results"] = palette.debugResults
            state["selected"] = .number(Double(palette.debugSelectedRow))
            state["query"] = .string(palette.query)
            state["panelIsKey"] = .bool(palette.debugPanel.isKeyWindow)
        }
        return .object(state)
    }
}
#endif
