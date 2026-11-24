import Foundation

/// A menu shortcut as the user writes it (`cmds shortcuts set splitRight cmd+shift+d`, #174 G14) and as AppKit
/// takes it: a key equivalent (the character, or a function key's private-use character) and modifiers.
public struct KeyShortcut: Equatable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    /// `NSMenuItem.keyEquivalent`: lower case for letters (shift is a modifier).
    public var key: String
    public var modifiers: Modifiers

    public init(key: String, modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    public struct Invalid: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    typealias NamedKey = (names: [String], key: String, symbol: String)

    // Function keys (NSEvent's private-use characters), by the name the user writes.
    static let named: [NamedKey] = {
        var keys: [NamedKey] = [
            (["left"], "\u{F702}", "←"), (["right"], "\u{F703}", "→"), (["up"], "\u{F700}", "↑"), (["down"], "\u{F701}", "↓"),
            (["return", "enter"], "\r", "↩"), (["tab"], "\t", "⇥"), (["space"], " ", "Space"),
            (["delete", "backspace"], "\u{8}", "⌫"), (["forwarddelete"], "\u{F728}", "⌦"), (["escape", "esc"], "\u{1b}", "⎋"),
            (["home"], "\u{F729}", "↖"), (["end"], "\u{F72B}", "↘"), (["pageup"], "\u{F72C}", "⇞"),
            (["pagedown"], "\u{F72D}", "⇟"), (["plus"], "+", "+"), (["minus"], "-", "-"),
        ]
        for number in 1...20 {
            let scalar = UnicodeScalar(UInt32(0xF703 + number))!
            keys.append((["f\(number)"], String(Character(scalar)), "F\(number)"))
        }
        return keys
    }()

    /// Reads `cmd+shift+d`, `ctrl+opt+left`, `cmd+,`, `f5` (also `⇧⌘D`). A key without ⌘, ⌃ or ⌥ is refused unless
    /// it is a function key (F1–F20): it would be taken from what you type in a terminal.
    public static func parse(_ text: String) throws -> KeyShortcut {
        var rest = text.trimmingCharacters(in: .whitespaces)
        var modifiers: Modifiers = []
        // Symbols first (⌃⌥⇧⌘D), then `name+` prefixes.
        let symbols: [(Character, Modifiers)] = [("⌃", .control), ("⌥", .option), ("⇧", .shift), ("⌘", .command)]
        while let first = rest.first, let symbol = symbols.first(where: { $0.0 == first }) {
            modifiers.insert(symbol.1)
            rest.removeFirst()
        }
        let names: [String: Modifiers] = ["cmd": .command, "command": .command, "ctrl": .control, "control": .control,
                                          "opt": .option, "option": .option, "alt": .option, "shift": .shift]
        while let plus = rest.dropFirst().firstIndex(of: "+") {
            let name = rest[..<plus].lowercased()
            guard let modifier = names[name] else { throw Invalid(description: "unknown modifier \"\(name)\" (cmd, ctrl, opt, shift)") }
            modifiers.insert(modifier)
            rest = String(rest[rest.index(after: plus)...])
        }
        guard !rest.isEmpty else { throw Invalid(description: "no key in \"\(text)\"") }
        let key: String
        let lower = rest.lowercased()
        if let entry = named.first(where: { $0.names.contains(lower) }) {
            key = entry.key
        } else if rest.count == 1, let scalar = rest.unicodeScalars.first, scalar.isASCII, scalar.value > 32 {
            key = lower
        } else {
            throw Invalid(description: "unknown key \"\(rest)\" (a letter, digit or sign, left/right/up/down, return, tab, space, delete, escape, home/end, pageup/pagedown, f1–f20)")
        }
        let shortcut = KeyShortcut(key: key, modifiers: modifiers)
        guard !modifiers.isDisjoint(with: [.command, .control, .option]) || shortcut.isFunctionKey else {
            throw Invalid(description: "\(shortcut.display) needs ⌘, ⌃ or ⌥ (else it would be taken from what you type)")
        }
        return shortcut
    }

    var isFunctionKey: Bool { (0xF704...0xF717).contains(key.unicodeScalars.first?.value ?? 0) }

    /// As menus show it: `⌃⌥⇧⌘D`, `⌥⌘←`, `F5`.
    public var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (Self.named.first { $0.key == key }?.symbol ?? key.uppercased())
    }

    /// The canonical form `parse` reads back: `ctrl+opt+shift+cmd+d`.
    public var spec: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        return (parts + [Self.named.first { $0.key == key }?.names[0] ?? key]).joined(separator: "+")
    }

    /// The same keys as pressed: an upper-case key equivalent means shift (`"D"` with ⌘ is ⇧⌘D).
    public var normalized: KeyShortcut {
        let lower = key.lowercased()
        guard lower != key else { return self }
        return KeyShortcut(key: lower, modifiers: modifiers.union(.shift))
    }
}
