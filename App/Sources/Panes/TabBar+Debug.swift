#if DEBUG
import AppKit
import CmdsCore

/// Tests only (`debug.tab_bar`, docs/internals/testing.md): drives a tab bar with synthesized mouse events through
/// its own handlers (mouseDown / mouseUp / otherMouseUp / menu(for:)), as a real mouse would, and reports its state.
/// Dragging needs a real mouse (a dragging session cannot be synthesized).
@MainActor
enum TabBarDebug {
    /// `pane` (any tab of the group) and `action`: `state` (default), `click {index}`, `middleClick {index}`,
    /// `close {index}` (the ×), `menu {index, choose?}` (the context menu's titles; `choose` runs one),
    /// `overflow {choose?}` (the ⌄ menu's titles; `choose` shows that tab), `resize {width}` (the bar's width, to test
    /// overflow), `suspension {run?}` (browser tabs' suspension inputs; `run` suspends idle ones now). Returns the bar's
    /// state after the action.
    static func perform(_ params: JSONValue?, controller: AppController) throws -> JSONValue {
        guard let paneID = params?["pane"]?.stringValue,
              let window = controller.window?.windowController as? MainWindowController else {
            throw RPCError.invalidParams("pane must name a tab")
        }
        window.content.view.layoutSubtreeIfNeeded()
        guard let bar = window.content.tabBar(forPane: paneID) else { throw RPCError.notFound("no tab bar on screen for \(paneID)") }
        var result: [String: JSONValue] = [:]
        let index = params?["index"]?.intValue
        func point(_ index: Int?, close: Bool = false) throws -> NSPoint {
            guard let index, bar.visible.contains(index) else { throw RPCError.invalidParams("index must be a visible tab") }
            return bar.debugPoint(index: index, close: close)
        }
        switch params?["action"]?.stringValue ?? "state" {
        case "state": break
        case "click":
            let p = try point(index)
            bar.mouseDown(with: event(.leftMouseDown, p, bar))
            bar.mouseUp(with: event(.leftMouseUp, p, bar))
        case "middleClick":
            bar.middleClicked(at: try point(index))
        case "close":
            let p = try point(index, close: true)
            bar.mouseMoved(with: event(.mouseMoved, p, bar))
            bar.mouseDown(with: event(.leftMouseDown, p, bar))
            bar.mouseUp(with: event(.leftMouseUp, p, bar))
        case "menu":
            guard let menu = bar.menu(for: event(.rightMouseDown, try point(index), bar)) else { throw RPCError.notFound("no menu") }
            result["menu"] = .array(menu.items.filter { !$0.isSeparatorItem }.map { .string($0.title) })
            try choose(params?["choose"]?.stringValue, in: menu)
        case "overflow":
            let menu = bar.overflowMenu()
            result["menu"] = .array(menu.items.map { .string($0.title) })
            try choose(params?["choose"]?.stringValue, in: menu)
        case "suspension":
            // Each browser tab's suspension inputs; `run: true` checks and suspends now (as the minute timer does).
            if params?["run"]?.boolValue == true { controller.suspendIdleTabs() }
            let now = Date()
            result["suspension"] = .array(bar.tabs.compactMap { tab -> JSONValue? in
                guard let browser = controller.pane(id: tab.paneID)?.browser else { return nil }
                return .object(["pane": .string(tab.paneID),
                                "hiddenFor": .number(browser.hiddenSince.map { now.timeIntervalSince($0) } ?? -1),
                                "unusedFor": .number(now.timeIntervalSince(browser.lastUsed)),
                                "loading": .bool(browser.webView.isLoading), "fromForm": .bool(browser.loadedFromForm),
                                "canSuspend": .bool(browser.canSuspend), "suspended": .bool(browser.isSuspended),
                                "inWindow": .bool(browser.window != nil)])
            })
        case "resize":
            guard let width = params?["width"]?.intValue, width > 0 else { throw RPCError.invalidParams("width must be positive") }
            bar.setFrameSize(NSSize(width: CGFloat(width), height: bar.frame.height))
        case let other:
            throw RPCError.invalidParams("unknown action \(other)")
        }
        // After the action the views may be rebuilt: report the bar on screen now.
        window.content.view.layoutSubtreeIfNeeded()
        let now = window.content.tabBar(forPane: paneID) ?? bar
        result["tabs"] = .array(now.tabs.map { .string($0.paneID) })
        result["titles"] = .array(now.tabs.map { .string($0.title) })
        result["selected"] = now.selectedID.map(JSONValue.string) ?? .null
        result["visible"] = .array([.number(Double(now.visible.lowerBound)), .number(Double(now.visible.upperBound))])
        result["icons"] = .array(now.tabs.map { .bool($0.icon != nil) })
        result["focused"] = controller.selectedWorkspace?.focusedPaneID.map(JSONValue.string) ?? .null
        return .object(result)
    }

    private static func choose(_ title: String?, in menu: NSMenu) throws {
        guard let title else { return }
        guard let item = menu.items.first(where: { $0.title == title }), let action = item.action else {
            throw RPCError.invalidParams("no menu item \(title)")
        }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    private static func event(_ type: NSEvent.EventType, _ point: NSPoint, _ view: NSView) -> NSEvent {
        let location = view.convert(point, to: nil)
        return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                  windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                  clickCount: 1, pressure: 1)!
    }
}

extension TabBarView {
    /// The middle of a tab, or of its ×.
    func debugPoint(index: Int, close: Bool) -> NSPoint {
        debugRects(index).map { close ? NSPoint(x: $0.close.midX, y: $0.close.midY) : NSPoint(x: $0.tab.midX, y: $0.tab.midY) }
            ?? .zero
    }
}
#endif
