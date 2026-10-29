import Foundation

// Wire messages for the iOS companion sync. Each message is one flat JSON object whose `type`
// field selects the case, e.g. {"type":"input","paneID":"p1","text":"ls\n"}. See docs/SYNC.md.

// MARK: - Phone → Mac

public enum ClientMessage: Equatable, Sendable {
    case hello(Hello)
    case subscribe(Subscribe)
    case requestScreen(RequestScreen)
    case input(Input)
    case key(Key)
    case selectWorkspace(SelectWorkspace)
    case focusPane(FocusPane)
    case ping(Ping)
    case requestFile(RequestFile)

    /// First message on every connection. Give `token` when one is stored for this Mac,
    /// otherwise `pairingCode` (the 6 digits shown on the Mac).
    public struct Hello: Codable, Equatable, Sendable {
        public var protocolVersion: Int
        public var deviceName: String
        /// Stable per-install identifier (lets the Mac list/revoke paired devices).
        public var deviceID: String?
        public var pairingCode: String?
        public var token: String?
        /// Optional protocol additions this phone understands (`SyncFeature`); absent from older phones.
        public var features: [String]?

        public init(protocolVersion: Int = SyncProtocol.version, deviceName: String, deviceID: String? = nil,
                    pairingCode: String? = nil, token: String? = nil, features: [String]? = nil) {
            self.protocolVersion = protocolVersion
            self.deviceName = deviceName
            self.deviceID = deviceID
            self.pairingCode = pairingCode
            self.token = token
            self.features = features
        }
    }

    /// Replace the set of panes whose screen is streamed. The Mac answers with a full `screen`
    /// for every newly subscribed pane, then diffs/fulls on change. Empty list = stop streaming.
    public struct Subscribe: Codable, Equatable, Sendable {
        public var paneIDs: [String]
        public init(paneIDs: [String]) { self.paneIDs = paneIDs }
    }

    /// Ask for a full `screen` (e.g. after a `screenDiff` whose `baseSeq` did not match).
    public struct RequestScreen: Codable, Equatable, Sendable {
        public var paneID: String
        public init(paneID: String) { self.paneID = paneID }
    }

    /// Text typed into a pane (UTF-8, sent as if pasted/typed; "\n" is not translated).
    public struct Input: Codable, Equatable, Sendable {
        public var paneID: String
        public var text: String
        public init(paneID: String, text: String) {
            self.paneID = paneID
            self.text = text
        }
    }

    public struct Key: Codable, Equatable, Sendable {
        public var paneID: String
        public var key: SyncKey
        public init(paneID: String, key: SyncKey) {
            self.paneID = paneID
            self.key = key
        }
    }

    public struct SelectWorkspace: Codable, Equatable, Sendable {
        public var id: String
        public init(id: String) { self.id = id }
    }

    public struct FocusPane: Codable, Equatable, Sendable {
        public var id: String
        public init(id: String) { self.id = id }
    }

    /// Ask for the file shown in a preview pane (never an arbitrary path). Answered with `file` message(s),
    /// or `error` (`notFound`, `badRequest`). Older Macs answer `error{badRequest}` (unknown type).
    public struct RequestFile: Codable, Equatable, Sendable {
        public var paneID: String
        public init(paneID: String) { self.paneID = paneID }
    }

    public struct Ping: Codable, Equatable, Sendable {
        /// Echoed in `pong` (optional, for RTT measurement).
        public var nonce: Int?
        public init(nonce: Int? = nil) { self.nonce = nonce }
    }

    public var typeName: String {
        switch self {
        case .hello: return "hello"
        case .subscribe: return "subscribe"
        case .requestScreen: return "requestScreen"
        case .input: return "input"
        case .key: return "key"
        case .selectWorkspace: return "selectWorkspace"
        case .focusPane: return "focusPane"
        case .ping: return "ping"
        case .requestFile: return "requestFile"
        }
    }
}

// MARK: - Mac → Phone

public enum ServerMessage: Equatable, Sendable {
    case welcome(Welcome)
    case error(ErrorInfo)
    case state(State)
    case screen(Screen)
    case screenDiff(ScreenDiff)
    case notification(Notification)
    case pong(Pong)
    case file(File)

    /// Authentication succeeded. The phone stores `token` (Keychain, per Mac) for future connects.
    public struct Welcome: Codable, Equatable, Sendable {
        public var protocolVersion: Int
        public var macName: String
        public var token: String

        public init(protocolVersion: Int = SyncProtocol.version, macName: String, token: String) {
            self.protocolVersion = protocolVersion
            self.macName = macName
            self.token = token
        }
    }

    public struct ErrorInfo: Codable, Equatable, Sendable {
        public var code: SyncErrorCode
        public var message: String
        public init(code: SyncErrorCode, message: String) {
            self.code = code
            self.message = message
        }
    }

    /// Full workspace snapshot, sent after `welcome` and whenever anything in it changes
    /// (resource-usage-only changes at most every ~2 s).
    public struct State: Codable, Equatable, Sendable {
        public var workspaces: [WorkspaceInfo]
        /// Machine-wide CPU/memory. Optional so older Macs and phones interoperate.
        public var system: SystemStats?
        /// Latest account limits of the coding agents (Claude, Codex). Optional, omitted when none is known.
        public var agentLimits: [AgentLimits]?

        public init(workspaces: [WorkspaceInfo], system: SystemStats? = nil, agentLimits: [AgentLimits]? = nil) {
            self.workspaces = workspaces
            self.system = system
            self.agentLimits = agentLimits
        }
    }

    /// Full screen of a pane. `seq` increases per pane for every screen/screenDiff sent.
    public struct Screen: Codable, Equatable, Sendable {
        public var paneID: String
        public var seq: UInt64
        public var rows: Int
        public var cols: Int
        public var lines: [String]
        public var cursorRow: Int?
        public var cursorCol: Int?

        public init(paneID: String, seq: UInt64, rows: Int, cols: Int, lines: [String],
                    cursorRow: Int? = nil, cursorCol: Int? = nil) {
            self.paneID = paneID
            self.seq = seq
            self.rows = rows
            self.cols = cols
            self.lines = lines
            self.cursorRow = cursorRow
            self.cursorCol = cursorCol
        }

        public init(paneID: String, seq: UInt64, snapshot: ScreenSnapshot) {
            self.init(paneID: paneID, seq: seq, rows: snapshot.rows, cols: snapshot.cols, lines: snapshot.lines,
                      cursorRow: snapshot.cursorRow, cursorCol: snapshot.cursorCol)
        }

        public var snapshot: ScreenSnapshot {
            ScreenSnapshot(rows: rows, cols: cols, lines: lines, cursorRow: cursorRow, cursorCol: cursorCol)
        }
    }

    /// Changed rows relative to the screen with `seq == baseSeq`. Only sent when rows/cols are
    /// unchanged. Cursor fields are always the new absolute position (nil = hidden).
    public struct ScreenDiff: Codable, Equatable, Sendable {
        public var paneID: String
        public var seq: UInt64
        public var baseSeq: UInt64
        public var changes: [LineChange]
        public var cursorRow: Int?
        public var cursorCol: Int?

        public init(paneID: String, seq: UInt64, baseSeq: UInt64, changes: [LineChange],
                    cursorRow: Int? = nil, cursorCol: Int? = nil) {
            self.paneID = paneID
            self.seq = seq
            self.baseSeq = baseSeq
            self.changes = changes
            self.cursorRow = cursorRow
            self.cursorCol = cursorCol
        }
    }

    /// A pane raised a notification (agent waiting, command finished, OSC 9/777...).
    public struct Notification: Codable, Equatable, Sendable {
        public var paneID: String?
        public var workspaceID: String
        public var title: String
        public var body: String

        public init(paneID: String?, workspaceID: String, title: String, body: String) {
            self.paneID = paneID
            self.workspaceID = workspaceID
            self.title = title
            self.body = body
        }
    }

    public struct Pong: Codable, Equatable, Sendable {
        public var nonce: Int?
        public init(nonce: Int? = nil) { self.nonce = nonce }
    }

    /// One piece of the file of a preview pane (answer to `requestFile`). `data` (base64) holds bytes
    /// `offset ..< offset + data.count` of `size`; the file is complete when the pieces reach `size`.
    /// `truncated`: the file is larger than `SyncFile.maxBytes` (or unreadable), no data is sent.
    public struct File: Codable, Equatable, Sendable {
        public var paneID: String
        public var name: String
        public var mime: String
        /// Total byte count of the file being sent.
        public var size: Int
        public var offset: Int
        public var data: Data
        public var truncated: Bool?

        public init(paneID: String, name: String, mime: String, size: Int, offset: Int = 0, data: Data,
                    truncated: Bool? = nil) {
            self.paneID = paneID
            self.name = name
            self.mime = mime
            self.size = size
            self.offset = offset
            self.data = data
            self.truncated = truncated
        }
    }

    public var typeName: String {
        switch self {
        case .welcome: return "welcome"
        case .error: return "error"
        case .state: return "state"
        case .screen: return "screen"
        case .screenDiff: return "screenDiff"
        case .notification: return "notification"
        case .pong: return "pong"
        case .file: return "file"
        }
    }
}

// MARK: - Codable (flat object with `type` discriminator)

private enum SyncTypeKey: String, CodingKey { case type }

/// Thrown for a well-formed envelope whose `type` this build does not know.
public struct UnknownSyncMessageType: Error, Equatable, Sendable {
    public var type: String
}

extension ClientMessage: Codable {
    public init(from decoder: Decoder) throws {
        let type = try decoder.container(keyedBy: SyncTypeKey.self).decode(String.self, forKey: .type)
        switch type {
        case "hello": self = .hello(try Hello(from: decoder))
        case "subscribe": self = .subscribe(try Subscribe(from: decoder))
        case "requestScreen": self = .requestScreen(try RequestScreen(from: decoder))
        case "input": self = .input(try Input(from: decoder))
        case "key": self = .key(try Key(from: decoder))
        case "selectWorkspace": self = .selectWorkspace(try SelectWorkspace(from: decoder))
        case "focusPane": self = .focusPane(try FocusPane(from: decoder))
        case "ping": self = .ping(try Ping(from: decoder))
        case "requestFile": self = .requestFile(try RequestFile(from: decoder))
        default: throw UnknownSyncMessageType(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .hello(let p): try p.encode(to: encoder)
        case .subscribe(let p): try p.encode(to: encoder)
        case .requestScreen(let p): try p.encode(to: encoder)
        case .input(let p): try p.encode(to: encoder)
        case .key(let p): try p.encode(to: encoder)
        case .selectWorkspace(let p): try p.encode(to: encoder)
        case .focusPane(let p): try p.encode(to: encoder)
        case .ping(let p): try p.encode(to: encoder)
        case .requestFile(let p): try p.encode(to: encoder)
        }
        var c = encoder.container(keyedBy: SyncTypeKey.self)
        try c.encode(typeName, forKey: .type)
    }
}

extension ServerMessage: Codable {
    public init(from decoder: Decoder) throws {
        let type = try decoder.container(keyedBy: SyncTypeKey.self).decode(String.self, forKey: .type)
        switch type {
        case "welcome": self = .welcome(try Welcome(from: decoder))
        case "error": self = .error(try ErrorInfo(from: decoder))
        case "state": self = .state(try State(from: decoder))
        case "screen": self = .screen(try Screen(from: decoder))
        case "screenDiff": self = .screenDiff(try ScreenDiff(from: decoder))
        case "notification": self = .notification(try Notification(from: decoder))
        case "pong": self = .pong(try Pong(from: decoder))
        case "file": self = .file(try File(from: decoder))
        default: throw UnknownSyncMessageType(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .welcome(let p): try p.encode(to: encoder)
        case .error(let p): try p.encode(to: encoder)
        case .state(let p): try p.encode(to: encoder)
        case .screen(let p): try p.encode(to: encoder)
        case .screenDiff(let p): try p.encode(to: encoder)
        case .notification(let p): try p.encode(to: encoder)
        case .pong(let p): try p.encode(to: encoder)
        case .file(let p): try p.encode(to: encoder)
        }
        var c = encoder.container(keyedBy: SyncTypeKey.self)
        try c.encode(typeName, forKey: .type)
    }
}
