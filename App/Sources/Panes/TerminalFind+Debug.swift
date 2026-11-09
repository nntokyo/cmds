#if DEBUG
import AppKit
import CmdsCore

/// Tests only (`debug.find`, docs/internals/testing.md): drive a terminal pane's find bar without UI scripting.
extension TerminalFind {
    /// `action`: `state` (default); `open` (optional `text`, `caseSensitive`, `regex`: searches and waits for the result);
    /// `set` (the same without opening); `next` / `previous`; `close`; `key` (`chars`: a key press sent to the window
    /// as typed, e.g. to check that it never reaches the terminal while the bar is open); `menuKey` (`chars`, `shift`:
    /// a ⌘-key through the main menu, as pressing it would); `snapshot` adds a picture of the pane (`png_base64`).
    func debugPerform(_ params: JSONValue?) async throws -> JSONValue {
        let action = params?["action"]?.stringValue ?? "state"
        let text = params?["text"]?.stringValue
        let caseSensitive = params?["caseSensitive"]?.boolValue
        let regex = params?["regex"]?.boolValue
        switch action {
        case "state": break
        case "open", "set":
            if action == "open" { open() }
            guard isOpen else { throw RPCError.invalidParams("the find bar is not open") }
            debugSetOptions(caseSensitive: caseSensitive, regex: regex)
            if let text { debugSetText(text) }
            runSearch()
            await debugWaitUntilSettled()
        case "next", "previous":
            navigate(next: action == "next")
            await debugWaitUntilSettled()
            // libghostty reports the new selection from its search thread.
            try? await Task.sleep(nanoseconds: 300_000_000)
        case "close": close()
        case "key", "menuKey":
            guard let chars = params?["chars"]?.stringValue, !chars.isEmpty,
                  let window = debugContainer.window else { throw RPCError.invalidParams("chars (and an open window)") }
            let shift = params?["shift"]?.boolValue == true
            for character in chars {
                if action == "menuKey" {
                    // From a CGEvent, so AppKit fills in the characters as for a key press (⇧⌘G: "G").
                    guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: Self.debugKeyCode(character), keyDown: true)
                    else { continue }
                    cgEvent.flags = shift ? [.maskCommand, .maskShift] : [.maskCommand]
                    if let event = NSEvent(cgEvent: cgEvent) { _ = NSApp.mainMenu?.performKeyEquivalent(with: event) }
                } else if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [],
                                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: window.windowNumber, context: nil,
                                                       characters: String(character),
                                                       charactersIgnoringModifiers: String(character), isARepeat: false,
                                                       keyCode: Self.debugKeyCode(character)) {
                    window.sendEvent(event)
                }
            }
            await debugWaitUntilSettled()
            // libghostty reports a new selection from its search thread.
            try? await Task.sleep(nanoseconds: 300_000_000)
        default: throw RPCError.invalidParams("unknown action \(action)")
        }
        var state = debugState
        if params?["snapshot"]?.boolValue == true, case let view = debugContainer,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            state["png_base64"] = rep.representation(using: .png, properties: [:]).map { .string($0.base64EncodedString()) } ?? .null
        }
        return .object(state)
    }

    private func debugWaitUntilSettled() async {
        for _ in 0..<200 where !debugSettled {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// US-layout key codes for the characters tests type (Escape and Return included).
    private static func debugKeyCode(_ character: Character) -> UInt16 {
        let codes: [Character: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
                                          "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31,
                                          "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
                                          "\r": 36, "\u{1b}": 53, " ": 49]
        return codes[Character(character.lowercased())] ?? 0
    }
}
#endif
