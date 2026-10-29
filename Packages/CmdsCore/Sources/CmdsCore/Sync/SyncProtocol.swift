import Foundation

/// Constants for the iOS companion sync protocol. See docs/SYNC.md.
///
/// Transport: WebSocket (text frames, one JSON object per frame) over TCP on the local network.
/// The Mac advertises itself with Bonjour; every frame is a `ClientMessage` (phone → Mac) or
/// `ServerMessage` (Mac → phone) encoded by `SyncCodec`.
public enum SyncProtocol {
    /// Bump when a change is not backward compatible. The Mac rejects other versions with `unsupportedVersion`.
    public static let version = 1
    /// Bonjour service type advertised by the Mac.
    public static let bonjourServiceType = "_cmds._tcp"
    /// TXT record key: human-readable Mac name.
    public static let txtKeyName = "name"
    /// TXT record key: protocol version (decimal string).
    public static let txtKeyVersion = "version"
    /// Port used for manual entry when the user gives only a host.
    public static let defaultPort: UInt16 = 47_823
    /// Number of digits in the pairing code shown on the Mac.
    public static let pairingCodeLength = 6

    /// TXT record contents for the Bonjour advertisement.
    public static func txtRecord(macName: String) -> [String: String] {
        [txtKeyName: macName, txtKeyVersion: String(version)]
    }
}

// MARK: - Shared payload types

/// Special keys the phone can send. Raw values are the wire strings.
/// Arbitrary control chords use `ctrl(_:)` (wire form `ctrl-<letter>`).
public struct SyncKey: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let enter = SyncKey(rawValue: "enter")
    public static let tab = SyncKey(rawValue: "tab")
    public static let backTab = SyncKey(rawValue: "backtab")
    public static let escape = SyncKey(rawValue: "esc")
    public static let backspace = SyncKey(rawValue: "backspace")
    public static let delete = SyncKey(rawValue: "delete")
    public static let up = SyncKey(rawValue: "up")
    public static let down = SyncKey(rawValue: "down")
    public static let left = SyncKey(rawValue: "left")
    public static let right = SyncKey(rawValue: "right")
    public static let home = SyncKey(rawValue: "home")
    public static let end = SyncKey(rawValue: "end")
    public static let pageUp = SyncKey(rawValue: "pageup")
    public static let pageDown = SyncKey(rawValue: "pagedown")
    public static let ctrlC = SyncKey.ctrl("c")
    public static let ctrlD = SyncKey.ctrl("d")
    public static let ctrlZ = SyncKey.ctrl("z")
    public static let ctrlL = SyncKey.ctrl("l")

    /// Control chord, e.g. `ctrl("c")` → `ctrl-c`. Letters are lowercased.
    public static func ctrl(_ letter: Character) -> SyncKey {
        SyncKey(rawValue: "ctrl-" + String(letter).lowercased())
    }

    /// Letter of a `ctrl-x` key, or nil.
    public var controlLetter: Character? {
        guard rawValue.hasPrefix("ctrl-"), rawValue.count == 6 else { return nil }
        return rawValue.last
    }

    public var description: String { rawValue }

    /// Bytes a terminal expects for this key (xterm conventions). Useful for the Mac side when
    /// writing straight to the pty; nil for unknown keys.
    /// - Parameter applicationCursor: DECCKM state (arrows send `ESC O x` instead of `ESC [ x`).
    public func terminalBytes(applicationCursor: Bool = false) -> [UInt8]? {
        let esc: UInt8 = 0x1B
        func csi(_ s: String) -> [UInt8] { [esc, UInt8(ascii: "[")] + Array(s.utf8) }
        func arrow(_ c: Character) -> [UInt8] {
            [esc, applicationCursor ? UInt8(ascii: "O") : UInt8(ascii: "["), c.asciiValue!]
        }
        switch self {
        case .enter: return [0x0D]
        case .tab: return [0x09]
        case .backTab: return csi("Z")
        case .escape: return [esc]
        case .backspace: return [0x7F]
        case .delete: return csi("3~")
        case .up: return arrow("A")
        case .down: return arrow("B")
        case .right: return arrow("C")
        case .left: return arrow("D")
        case .home: return csi("H")
        case .end: return csi("F")
        case .pageUp: return csi("5~")
        case .pageDown: return csi("6~")
        default:
            guard let letter = controlLetter, let ascii = letter.asciiValue else { return nil }
            switch letter {
            case "a"..."z": return [ascii - UInt8(ascii: "a") + 1]
            case "@": return [0x00]
            case "[": return [0x1B]
            case "\\": return [0x1C]
            case "]": return [0x1D]
            case "^": return [0x1E]
            case "_": return [0x1F]
            default: return nil
            }
        }
    }
}

/// Error codes carried by `ServerMessage.error`. Unknown codes decode as-is (forward compatible).
public struct SyncErrorCode: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// `hello.protocolVersion` is not supported. Connection is closed.
    public static let unsupportedVersion = SyncErrorCode(rawValue: "unsupportedVersion")
    /// Neither a valid token nor a pairing code was given. Phone should show the pairing sheet.
    public static let pairingRequired = SyncErrorCode(rawValue: "pairingRequired")
    /// Pairing code wrong or expired.
    public static let invalidPairingCode = SyncErrorCode(rawValue: "invalidPairingCode")
    /// Stored token unknown/revoked. Phone should delete it and re-pair.
    public static let invalidToken = SyncErrorCode(rawValue: "invalidToken")
    /// Too many failed attempts; retry later.
    public static let rateLimited = SyncErrorCode(rawValue: "rateLimited")
    /// A message other than `hello` arrived before authentication.
    public static let notAuthenticated = SyncErrorCode(rawValue: "notAuthenticated")
    /// Malformed or unknown message.
    public static let badRequest = SyncErrorCode(rawValue: "badRequest")
    /// Referenced pane/workspace does not exist.
    public static let notFound = SyncErrorCode(rawValue: "notFound")
    public static let internalError = SyncErrorCode(rawValue: "internal")

    public var description: String { rawValue }

    /// Errors after which the connection is closed by the Mac and the phone must not auto-reconnect
    /// with the same credentials.
    public var isAuthFailure: Bool {
        [.pairingRequired, .invalidPairingCode, .invalidToken, .unsupportedVersion, .rateLimited].contains(self)
    }
}

/// One changed row in a `screenDiff`.
public struct LineChange: Codable, Equatable, Sendable {
    public var row: Int
    public var text: String

    public init(row: Int, text: String) {
        self.row = row
        self.text = text
    }
}

/// Plain-text screen contents of one terminal pane (what is visible, no scrollback).
public struct ScreenSnapshot: Codable, Equatable, Sendable {
    public var rows: Int
    public var cols: Int
    /// Exactly `rows` entries; trailing spaces may be trimmed by the sender.
    public var lines: [String]
    public var cursorRow: Int?
    public var cursorCol: Int?

    public init(rows: Int, cols: Int, lines: [String], cursorRow: Int? = nil, cursorCol: Int? = nil) {
        self.rows = rows
        self.cols = cols
        self.lines = lines
        self.cursorRow = cursorRow
        self.cursorCol = cursorCol
    }

    public static let empty = ScreenSnapshot(rows: 0, cols: 0, lines: [])
}
