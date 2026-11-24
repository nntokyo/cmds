import AppKit
import CmdsCore

/// Shortcuts of the main menu the user changes (#174 G14): `cmds shortcuts` lists every menu item with an action and
/// its key, `cmds shortcuts set ID KEYS` changes one (`""`: none) and `reset` brings back the default. Saved in
/// `AppSettings.customShortcuts`, applied at launch and at once when changed.
///
/// An item's id is its action without the colon (`splitRight`), the same in every language; items sharing an action
/// (Workspace 1–9) get `-1`, `-2`, … in menu order. Hidden alternates (⌃Tab, ⌘+) keep their keys and are not listed,
/// but their keys count as taken.
@MainActor
enum MenuShortcuts {
    struct Entry {
        let id: String
        /// `Pane › Split Right`, in the app's language.
        let path: String
        let item: NSMenuItem
        let defaultShortcut: KeyShortcut?
    }

    /// Each item's key as built, before any change (by item).
    private static var defaults: [ObjectIdentifier: KeyShortcut?] = [:]

    static func shortcut(of item: NSMenuItem) -> KeyShortcut? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        var modifiers: KeyShortcut.Modifiers = []
        let mask = item.keyEquivalentModifierMask
        if mask.contains(.control) { modifiers.insert(.control) }
        if mask.contains(.option) { modifiers.insert(.option) }
        if mask.contains(.shift) { modifiers.insert(.shift) }
        if mask.contains(.command) { modifiers.insert(.command) }
        return KeyShortcut(key: item.keyEquivalent, modifiers: modifiers).normalized
    }

    private static func set(_ shortcut: KeyShortcut?, on item: NSMenuItem) {
        // Cleared first: AppKit's key equivalent lookup otherwise keeps matching the old modifiers when only they
        // change (⌘D still split after Split Right became ⌃⌥D).
        item.keyEquivalent = ""
        item.keyEquivalentModifierMask = []
        var mask: NSEvent.ModifierFlags = []
        if let modifiers = shortcut?.modifiers {
            if modifiers.contains(.control) { mask.insert(.control) }
            if modifiers.contains(.option) { mask.insert(.option) }
            if modifiers.contains(.shift) { mask.insert(.shift) }
            if modifiers.contains(.command) { mask.insert(.command) }
        }
        item.keyEquivalentModifierMask = mask
        item.keyEquivalent = shortcut?.key ?? ""
    }

    /// Every menu item with an action, depth first; `visible` false also gives the hidden alternates.
    private static func items(in menu: NSMenu, path: [String], visible: Bool) -> [(path: [String], item: NSMenuItem)] {
        menu.items.flatMap { item -> [(path: [String], item: NSMenuItem)] in
            if let submenu = item.submenu { return items(in: submenu, path: path + [item.title], visible: visible) }
            guard item.action != nil, !item.isSeparatorItem, !(visible && item.isHidden) else { return [] }
            return [(path + [item.title], item)]
        }
    }

    static func entries(in menu: NSMenu? = NSApp.mainMenu) -> [Entry] {
        guard let menu else { return [] }
        let found = items(in: menu, path: [], visible: true)
        var counts: [String: Int] = [:]
        for (_, item) in found { counts[actionName(item), default: 0] += 1 }
        var seen: [String: Int] = [:]
        return found.map { path, item in
            let name = actionName(item)
            var id = name
            if counts[name, default: 0] > 1 {
                seen[name, default: 0] += 1
                id = "\(name)-\(seen[name]!)"
            }
            let original = defaults[ObjectIdentifier(item)] ?? shortcut(of: item)
            return Entry(id: id, path: path.joined(separator: " › "), item: item, defaultShortcut: original)
        }
    }

    private static func actionName(_ item: NSMenuItem) -> String {
        NSStringFromSelector(item.action!).replacingOccurrences(of: ":", with: "")
    }

    /// Remembers the built keys, then applies the saved changes (at launch, after `MainMenu.build`). A saved change
    /// whose item no longer exists, or whose key another item took meanwhile, is skipped.
    static func applySaved(to menu: NSMenu? = NSApp.mainMenu) {
        guard let menu else { return }
        for (_, item) in items(in: menu, path: [], visible: false) where defaults[ObjectIdentifier(item)] == nil {
            defaults[ObjectIdentifier(item)] = .some(shortcut(of: item))
        }
        let saved = AppSettings.shared.customShortcuts
        for entry in entries(in: menu) {
            guard let spec = saved[entry.id] else { continue }
            if spec.isEmpty {
                set(nil, on: entry.item)
            } else if let shortcut = try? KeyShortcut.parse(spec), owner(of: shortcut, in: menu, except: entry.item) == nil {
                set(shortcut, on: entry.item)
            }
        }
    }

    /// The item (other than `except`) that has `shortcut` now, hidden alternates included.
    private static func owner(of shortcut: KeyShortcut, in menu: NSMenu, except: NSMenuItem?) -> (path: [String], item: NSMenuItem)? {
        items(in: menu, path: [], visible: false).first { $0.item !== except && self.shortcut(of: $0.item) == shortcut }
    }

    // MARK: API

    struct Failure: Error {
        let message: String
    }

    /// `shortcuts.list`: every item, its key now and by default.
    static func list() -> JSONValue {
        .object(["shortcuts": .array(entries().map(json))])
    }

    private static func json(_ entry: Entry) -> JSONValue {
        let now = shortcut(of: entry.item)
        return .object([
            "id": .string(entry.id), "menu": .string(entry.path),
            "shortcut": now.map { .string($0.display) } ?? .null, "keys": now.map { .string($0.spec) } ?? .null,
            "default": entry.defaultShortcut.map { .string($0.display) } ?? .null,
            "custom": .bool(AppSettings.shared.customShortcuts[entry.id] != nil),
        ])
    }

    /// `shortcuts.set`: `keys` a shortcut, "" for none, nil for the default. Refused when another item has the key.
    static func set(id: String, keys: String?) throws -> JSONValue {
        guard let menu = NSApp.mainMenu, let entry = entries(in: menu).first(where: { $0.id == id }) else {
            throw Failure(message: "no menu item \"\(id)\" (see `cmds shortcuts`)")
        }
        var shortcut: KeyShortcut?
        if let keys, !keys.isEmpty {
            do { shortcut = try KeyShortcut.parse(keys) } catch let error as KeyShortcut.Invalid { throw Failure(message: error.description) }
        } else if keys == nil {
            shortcut = entry.defaultShortcut
        }
        if let shortcut, let other = owner(of: shortcut, in: menu, except: entry.item) {
            let otherID = entries(in: menu).first { $0.item === other.item }?.id
            throw Failure(message: "\(shortcut.display) is taken by \(other.path.joined(separator: " › "))"
                          + (otherID.map { " (\($0); free it with `cmds shortcuts set \($0) \"\"`)" } ?? ""))
        }
        set(shortcut, on: entry.item)
        var saved = AppSettings.shared.customShortcuts
        saved[entry.id] = keys == nil ? nil : (shortcut?.spec ?? "")
        AppSettings.shared.customShortcuts = saved
        return json(entry)
    }

    #if DEBUG
    /// `debug.key_equivalent`: `keys` pressed as the menu sees them (a synthesized key event, no window brought
    /// forward). Whether a menu item took it.
    /// US-layout key codes: AppKit matches key equivalents by the key as well as the character.
    private static let debugKeyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "o": 31, "u": 32, "i": 34, "p": 35,
        "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "\t": 48,
    ]

    /// Also the item that fired (from NSMenu's did-send-action notification), nil when none did.
    static func debugPress(_ keys: String) throws -> (handled: Bool, item: String?) {
        let shortcut: KeyShortcut
        do { shortcut = try KeyShortcut.parse(keys) } catch let error as KeyShortcut.Invalid { throw Failure(message: error.description) }
        var flags: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.control) { flags.insert(.control) }
        if shortcut.modifiers.contains(.option) { flags.insert(.option) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.shift) }
        if shortcut.modifiers.contains(.command) { flags.insert(.command) }
        let characters = shortcut.modifiers.contains(.shift) ? shortcut.key.uppercased() : shortcut.key
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: NSApp.mainWindow?.windowNumber ?? 0, context: nil,
                                           characters: characters, charactersIgnoringModifiers: shortcut.key,
                                           isARepeat: false, keyCode: debugKeyCodes[shortcut.key] ?? 0) else { return (false, nil) }
        var fired: String?
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didSendActionNotification, object: nil, queue: nil) { note in
            fired = (note.userInfo?["MenuItem"] as? NSMenuItem).map { NSStringFromSelector($0.action!) + " " + $0.title }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let handled = NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
        return (handled, fired)
    }
    #endif

    /// `shortcuts.reset`: every item back to its default.
    static func resetAll() {
        AppSettings.shared.customShortcuts = [:]
        for entry in entries() { set(entry.defaultShortcut, on: entry.item) }
    }
}
