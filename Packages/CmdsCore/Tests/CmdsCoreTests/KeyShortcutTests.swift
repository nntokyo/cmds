import Foundation
import XCTest
@testable import CmdsCore

/// Menu shortcuts as written in `cmds shortcuts set` (#174 G14).
final class KeyShortcutTests: XCTestCase {
    func testParseAndShow() throws {
        let cases: [(String, String, String)] = [
            ("cmd+shift+d", "⇧⌘D", "shift+cmd+d"),
            ("Ctrl+Opt+Left", "⌃⌥⌘←".replacingOccurrences(of: "⌘", with: ""), "ctrl+opt+left"),
            ("cmd+,", "⌘,", "cmd+,"),
            ("cmd++", "⌘+", "cmd+plus"),
            ("cmd+plus", "⌘+", "cmd+plus"),
            ("f5", "F5", "f5"),
            ("⇧⌘D", "⇧⌘D", "shift+cmd+d"),
            ("alt+cmd+return", "⌥⌘↩", "opt+cmd+return"),
        ]
        for (text, display, spec) in cases {
            let shortcut = try KeyShortcut.parse(text)
            XCTAssertEqual(shortcut.display, display, text)
            XCTAssertEqual(shortcut.spec, spec, text)
            XCTAssertEqual(try KeyShortcut.parse(shortcut.spec), shortcut, "round trip of \(text)")
        }
        XCTAssertEqual(try KeyShortcut.parse("cmd+left").key, "\u{F702}")
        XCTAssertEqual(try KeyShortcut.parse("f1").key, "\u{F704}")
    }

    func testInvalid() {
        for text in ["", "d", "shift+d", "cmd+", "hyper+d", "cmd+abc", "cmd+é", "space"] {
            XCTAssertThrowsError(try KeyShortcut.parse(text), text)
        }
    }

    func testNormalized() {
        XCTAssertEqual(KeyShortcut(key: "D", modifiers: .command).normalized, KeyShortcut(key: "d", modifiers: [.command, .shift]))
        XCTAssertEqual(KeyShortcut(key: "[", modifiers: .command).normalized, KeyShortcut(key: "[", modifiers: .command))
    }
}
