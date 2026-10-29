import AppKit
import GhosttyKit

/// `TerminalSurface.sendText` support: turns a string (which may contain control characters and
/// escape sequences, e.g. key bytes forwarded from the iOS companion) into libghostty input.
///
/// - Printable runs → `ghostty_surface_text` (paste semantics: bracketed only if the program enabled it).
/// - `\r`, `\n`, `\r\n` → Return key; Tab, Backspace (0x08/0x7F), Ctrl+A…Z → real key presses.
/// - Lone ESC → Escape key.
/// - CSI / SS3 cursor, editing and function keys (`ESC [ A`, `ESC O A`, `ESC [ 3 ~`, `ESC [ 1 ; 5 C`,
///   `ESC [ Z`, …) → the matching key press, so libghostty encodes them for the current terminal modes
///   (normal vs application cursor keys, kitty keyboard protocol).
/// - Any other escape sequence (`ESC b`, `ESC [ 200 ~`, …) and the remaining C0 controls → raw bytes
///   written to the pty via the `text:` binding action (never bracketed).
@MainActor
extension GhosttySurfaceView {
    private enum VK {
        static let returnKey: UInt16 = 0x24
        static let tab: UInt16 = 0x30
        static let backspace: UInt16 = 0x33
        static let escape: UInt16 = 0x35
        static let left: UInt16 = 0x7B
        static let right: UInt16 = 0x7C
        static let down: UInt16 = 0x7D
        static let up: UInt16 = 0x7E
        static let insert: UInt16 = 0x72
        static let home: UInt16 = 0x73
        static let pageUp: UInt16 = 0x74
        static let forwardDelete: UInt16 = 0x75
        static let end: UInt16 = 0x77
        static let pageDown: UInt16 = 0x79
        static let f1: UInt16 = 0x7A, f2: UInt16 = 0x78, f3: UInt16 = 0x63, f4: UInt16 = 0x76
        static let f5: UInt16 = 0x60, f6: UInt16 = 0x61, f7: UInt16 = 0x62, f8: UInt16 = 0x64
        static let f9: UInt16 = 0x65, f10: UInt16 = 0x6D, f11: UInt16 = 0x67, f12: UInt16 = 0x6F
    }

    func sendText(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        let scalars = Array(text.unicodeScalars)
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            let chunk = buffer
            buffer = ""
            chunk.withCString { ghostty_surface_text(surface, $0, UInt(chunk.utf8.count)) }
        }

        var i = 0
        while i < scalars.count {
            let v = scalars[i].value
            switch v {
            case 0x0D:
                flush()
                sendKey(keyCode: VK.returnKey, unshifted: 0x0D)
                if i + 1 < scalars.count, scalars[i + 1].value == 0x0A { i += 1 }  // CRLF = one Return
            case 0x0A:
                flush()
                sendKey(keyCode: VK.returnKey, unshifted: 0x0D)
            case 0x09:
                flush()
                sendKey(keyCode: VK.tab, unshifted: 0x09)
            case 0x08, 0x7F:
                flush()
                sendKey(keyCode: VK.backspace, unshifted: 0x7F)
            case 0x1B:
                flush()
                i = sendEscape(scalars, at: i)
            case 0x01...0x1A:
                flush()
                let idx = Int(v - 1)
                sendKey(keyCode: GhosttyInput.letterKeyCodes[idx], mods: GHOSTTY_MODS_CTRL,
                        unshifted: 0x61 + UInt32(idx))
            case 0x00, 0x1C...0x1F:
                flush()
                writeRaw([UInt8(v)])
            default:
                buffer.unicodeScalars.append(scalars[i])
            }
            i += 1
        }
        flush()
    }

    /// Handles the escape sequence starting at `start` (an ESC). Returns the index of the last consumed scalar.
    private func sendEscape(_ s: [Unicode.Scalar], at start: Int) -> Int {
        let n = s.count
        guard start + 1 < n else {
            sendKey(keyCode: VK.escape, unshifted: 0x1B)
            return start
        }
        let next = s[start + 1].value

        // CSI: ESC [ params(0x30-0x3F)* intermediates(0x20-0x2F)* final(0x40-0x7E)
        if next == 0x5B {
            var j = start + 2
            var params = ""
            var hasIntermediates = false
            while j < n, (0x30...0x3F).contains(s[j].value) {
                params.unicodeScalars.append(s[j])
                j += 1
            }
            while j < n, (0x20...0x2F).contains(s[j].value) {
                hasIntermediates = true
                j += 1
            }
            guard j < n, (0x40...0x7E).contains(s[j].value) else {
                // Incomplete or malformed: pass through what we have; reprocess the offending scalar.
                writeRaw(s[start..<j])
                return j - 1
            }
            if !hasIntermediates, let key = Self.csiKey(params: params, final: s[j].value) {
                sendKey(keyCode: key.keyCode, mods: key.mods, unshifted: key.unshifted)
            } else {
                writeRaw(s[start...j])
            }
            return j
        }

        // SS3: ESC O final
        if next == 0x4F, start + 2 < n, (0x40...0x7E).contains(s[start + 2].value) {
            if let key = Self.ss3Key(final: s[start + 2].value) {
                sendKey(keyCode: key, unshifted: 0)
            } else {
                writeRaw(s[start...(start + 2)])
            }
            return start + 2
        }

        // ESC + any other character = Alt/Meta+character (ESC b, ESC DEL, ESC CR, …): raw.
        writeRaw(s[start...(start + 1)])
        return start + 1
    }

    /// Maps a CSI key sequence to a key press. nil = not a key we recognise (sent raw instead).
    private static func csiKey(params: String, final: UInt32) -> (keyCode: UInt16, mods: ghostty_input_mods_e, unshifted: UInt32)? {
        // Only plain numeric params: "", "N", "N;M". Private markers (<=>?) and sub-params (:) go raw.
        guard params.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || $0 == ";" }) else { return nil }
        let parts = params.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2 else { return nil }
        guard let p1 = parts[0].isEmpty ? 1 : Int(parts[0]) else { return nil }
        var modParam = 1
        if parts.count == 2 {
            guard let m = parts[1].isEmpty ? 1 : Int(parts[1]), (1...16).contains(m) else { return nil }
            modParam = m
        }
        // xterm modifier parameter: 1 + (shift 1 | alt 2 | ctrl 4 | meta 8).
        let bits = modParam - 1
        var mods = GHOSTTY_MODS_NONE.rawValue
        if bits & 1 != 0 { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if bits & 2 != 0 { mods |= GHOSTTY_MODS_ALT.rawValue }
        if bits & 4 != 0 { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if bits & 8 != 0 { mods |= GHOSTTY_MODS_SUPER.rawValue }

        let keyCode: UInt16
        var unshifted: UInt32 = 0
        switch Character(Unicode.Scalar(UInt8(truncatingIfNeeded: final))) {
        case "A": keyCode = VK.up
        case "B": keyCode = VK.down
        case "C": keyCode = VK.right
        case "D": keyCode = VK.left
        case "H": keyCode = VK.home
        case "F": keyCode = VK.end
        case "P": keyCode = VK.f1
        case "Q": keyCode = VK.f2
        case "R": keyCode = VK.f3
        case "S": keyCode = VK.f4
        case "Z":
            keyCode = VK.tab
            unshifted = 0x09
            mods |= GHOSTTY_MODS_SHIFT.rawValue
        case "~":
            switch p1 {
            case 1, 7: keyCode = VK.home
            case 2: keyCode = VK.insert
            case 3: keyCode = VK.forwardDelete
            case 4, 8: keyCode = VK.end
            case 5: keyCode = VK.pageUp
            case 6: keyCode = VK.pageDown
            case 11: keyCode = VK.f1
            case 12: keyCode = VK.f2
            case 13: keyCode = VK.f3
            case 14: keyCode = VK.f4
            case 15: keyCode = VK.f5
            case 17: keyCode = VK.f6
            case 18: keyCode = VK.f7
            case 19: keyCode = VK.f8
            case 20: keyCode = VK.f9
            case 21: keyCode = VK.f10
            case 23: keyCode = VK.f11
            case 24: keyCode = VK.f12
            default: return nil
            }
            return (keyCode, ghostty_input_mods_e(mods), unshifted)
        default:
            return nil
        }
        // Letter-final forms carry no key number other than the default 1 ("ESC [ 1 ; 5 A").
        guard p1 == 1 else { return nil }
        return (keyCode, ghostty_input_mods_e(mods), unshifted)
    }

    private static func ss3Key(final: UInt32) -> UInt16? {
        switch Character(Unicode.Scalar(UInt8(truncatingIfNeeded: final))) {
        case "A": return VK.up
        case "B": return VK.down
        case "C": return VK.right
        case "D": return VK.left
        case "H": return VK.home
        case "F": return VK.end
        case "P": return VK.f1
        case "Q": return VK.f2
        case "R": return VK.f3
        case "S": return VK.f4
        default: return nil
        }
    }

    private func writeRaw<C: Collection>(_ scalars: C) where C.Element == Unicode.Scalar {
        var s = ""
        s.unicodeScalars.append(contentsOf: scalars)
        writeRaw(Array(s.utf8))
    }
}
