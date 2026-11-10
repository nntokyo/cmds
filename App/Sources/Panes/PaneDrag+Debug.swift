#if DEBUG
import AppKit
import CmdsCore

/// Tests only (`debug.pane_drag`, docs/internals/testing.md, #218): pane drops without a mouse. A drop goes through
/// the same code as a real one: the content area's hit test and drop zones, the sidebar row's check, or the grip's
/// "ended outside the window".
@MainActor
enum PaneDragDebug {
    /// `pane` and one of: `target` (a pane) with `zone` (left, right, top, bottom, center; default center): drops at
    /// the middle of that zone of the target as laid out now; `row` (a workspace id): drops on its sidebar row;
    /// `outside: true`: drops outside the window. Without any, reports. Returns the pane's state after the drop
    /// (`state`), and for a target drop what the hit test found (`dropTarget`, `side`, `highlight`).
    static func perform(_ params: JSONValue?, controller: AppController) throws -> JSONValue {
        guard let paneID = params?["pane"]?.stringValue, let pane = controller.pane(id: paneID) else {
            throw RPCError.invalidParams("pane must name a pane")
        }
        guard let window = controller.window?.windowController as? MainWindowController else {
            throw RPCError.notFound("no main window")
        }
        var result: [String: JSONValue] = [:]
        if let target = params?["target"]?.stringValue {
            guard let targetPane = controller.pane(id: target), targetPane.container.window != nil else {
                throw RPCError.invalidParams("target must be a pane on screen")
            }
            let rawZone = params?["zone"]?.stringValue ?? "center"
            guard let zone = TileDropZone(rawValue: rawZone) else { throw RPCError.invalidParams("unknown zone \(rawZone)") }
            let content = window.content
            content.view.layoutSubtreeIfNeeded()
            let frame = targetPane.container.convert(targetPane.container.bounds, to: content.view)
            let point = point(in: frame, zone: zone)
            guard let drop = content.paneDropTarget(moving: paneID, at: point) else {
                throw RPCError.invalidParams("nothing to drop on at \(point) (the dragged pane itself?)")
            }
            result["dropTarget"] = .string(drop.target)
            result["side"] = drop.side.map { .string($0.rawValue) } ?? .string("center")
            result["highlight"] = rect(drop.highlight)
            controller.dropPane(paneID, PaneDrop(on: drop.target, side: drop.side))
        } else if let row = params?["row"]?.stringValue {
            guard window.sidebar.debugDropPane(paneID, onWorkspace: row) else {
                throw RPCError.invalidParams("the row of \(row) does not take this pane")
            }
        } else if params?["outside"]?.boolValue == true {
            pane.container.dragHandle.onDraggedOutOfWindow?()
        }
        window.content.view.layoutSubtreeIfNeeded()
        result["state"] = state(of: pane, controller: controller)
        return .object(result)
    }

    /// The middle of `zone`'s band in `frame` (flipped).
    private static func point(in frame: NSRect, zone: TileDropZone) -> NSPoint {
        let edge = TileDropZone.edgeFraction / 2
        switch zone {
        case .left: return NSPoint(x: frame.minX + frame.width * edge, y: frame.midY)
        case .right: return NSPoint(x: frame.maxX - frame.width * edge, y: frame.midY)
        case .top: return NSPoint(x: frame.midX, y: frame.minY + frame.height * edge)
        case .bottom: return NSPoint(x: frame.midX, y: frame.maxY - frame.height * edge)
        case .center: return NSPoint(x: frame.midX, y: frame.midY)
        }
    }

    /// Where the pane is now: its workspace, whether it is in the window, its frame there and a terminal's grid.
    private static func state(of pane: Pane, controller: AppController) -> JSONValue {
        let container = pane.container
        var state: [String: JSONValue] = [
            "workspace": .string(pane.workspaceID),
            "inWindow": .bool(container.window != nil),
            "focused": .bool(controller.workspace(id: pane.workspaceID)?.focusedPaneID == pane.id),
        ]
        if container.window != nil { state["frame"] = rect(container.convert(container.bounds, to: nil)) }
        // The grip, in the pane's coordinates (origin bottom-left): top centre whatever the pane's size.
        state["grip"] = rect(container.dragHandle.frame)
        if let grid = pane.terminal?.gridSize {
            state["grid"] = ["rows": .number(Double(grid.rows)), "cols": .number(Double(grid.cols))]
        }
        if let terminal = pane.terminal {
            state["firstResponder"] = .bool(container.window?.firstResponder === terminal.view)
        }
        return .object(state)
    }

    private static func rect(_ rect: NSRect) -> JSONValue {
        ["x": .number(Double(rect.minX)), "y": .number(Double(rect.minY)),
         "width": .number(Double(rect.width)), "height": .number(Double(rect.height))]
    }
}
#endif
