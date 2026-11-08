#if DEBUG
import AppKit
import CmdsCore

extension RecentAgentSessionsMenu {
    /// Tests only (`debug.recent_sessions`): the items File › Recent Agent Sessions would show, and with `open` (index
    /// of a session item) what choosing it does, without UI scripting; `snapshot` adds a picture of the window. Returns the items and the problem, if any.
    func debugPerform(_ params: JSONValue?) -> JSONValue {
        let menu = makeMenu()
        menuNeedsUpdate(menu)
        var result: [String: JSONValue] = [
            "items": .array(menu.items.map { item in
                .object([
                    "title": .string(item.isSeparatorItem ? "-" : item.title),
                    "checked": .bool(item.state == .on),
                    "enabled": .bool(item.isEnabled),
                    "wired": .bool(item.isSeparatorItem || item.action == nil || item.target != nil),
                    "toolTip": .string(item.toolTip ?? ""),
                ])
            }),
        ]
        if case .number(let index)? = params?["open"] {
            let items = menu.items.filter { $0.representedObject is AgentSession }
            if let item = items[safe: Int(index)], let session = item.representedObject as? AgentSession {
                result["problem"] = controller.openRecentAgentSession(session).map(JSONValue.string) ?? .null
            } else {
                result["problem"] = .string("no such item")
            }
        }
        if params?["snapshot"] == .bool(true), let view = controller.window?.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            // The sidebar's clock button next to New Workspace (window content drawn off screen).
            view.cacheDisplay(in: view.bounds, to: rep)
            result["png_base64"] = rep.representation(using: .png, properties: [:]).map { .string($0.base64EncodedString()) } ?? .null
        }
        return .object(result)
    }
}
#endif
