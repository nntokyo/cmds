import Foundation

/// Wire format for the socket API: one JSON object per line (UTF-8, `\n` terminated).
///
/// Request:  {"id": 1, "method": "pane.split", "params": {...}}
/// Response: {"id": 1, "result": {...}}  or  {"id": 1, "error": {"code": -32601, "message": "..."}}
/// Event:    {"event": "notification", "params": {...}}   (only on subscribed connections)
public struct RPCRequest: Codable, Sendable {
    public var id: Int
    public var method: String
    public var params: JSONValue?

    public init(id: Int, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct RPCError: Codable, Error, Sendable {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public static func methodNotFound(_ method: String) -> RPCError { .init(code: -32601, message: "method not found: \(method)") }
    public static func invalidParams(_ message: String) -> RPCError { .init(code: -32602, message: message) }
    public static func notFound(_ message: String) -> RPCError { .init(code: 404, message: message) }
}

public struct RPCResponse: Codable, Sendable {
    public var id: Int
    public var result: JSONValue?
    public var error: RPCError?

    public init(id: Int, result: JSONValue? = nil, error: RPCError? = nil) {
        self.id = id
        self.result = result
        self.error = error
    }
}

public struct RPCEvent: Codable, Sendable {
    public var event: String
    public var params: JSONValue?

    public init(event: String, params: JSONValue? = nil) {
        self.event = event
        self.params = params
    }
}

/// Environment variables injected into every terminal the app spawns, plus test-isolation switches.
public enum CmdsEnv {
    public static let socketPath = "CMDS_SOCKET_PATH"
    public static let workspaceID = "CMDS_WORKSPACE_ID"
    public static let paneID = "CMDS_PANE_ID"
    /// Isolated (test) instance: replaces `~/Library/Application Support/cmds` (session.json,
    /// sync-devices.json, cmds.sock). Terminals of such an instance inherit it, so their CLI follows.
    public static let supportDirectory = "CMDS_SUPPORT_DIR"
    /// `1` = do not start the iOS sync server (no Bonjour advert, no port).
    public static let syncDisabled = "CMDS_SYNC_DISABLED"
    /// Listen port of the iOS sync server instead of `SyncProtocol.defaultPort` (isolated test instances).
    /// Unlike the default port, it is never replaced by another one when it is taken.
    public static let syncPort = "CMDS_SYNC_PORT"
    /// `1` = run the iOS sync server without the Bonjour advertisement, so no phone discovers the instance.
    public static let syncNoBonjour = "CMDS_SYNC_NO_BONJOUR"
    /// `1` = no Bluetooth fallback (no advertising, no L2CAP channel), so no phone finds the instance over Bluetooth.
    public static let syncNoBluetooth = "CMDS_SYNC_NO_BLUETOOTH"

    public enum SyncPortSetting: Equatable, Sendable {
        case unset
        case port(UInt16)
        /// Set, but not a port number 1–65535 (the raw value, shortened).
        case invalid(String)
    }

    /// `$CMDS_SUPPORT_DIR` if set, else `~/Library/Application Support/cmds`.
    public static func supportDirectoryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = supportDirectoryOverride(environment: environment) {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/cmds", isDirectory: true)
    }

    /// Absolute `$CMDS_SUPPORT_DIR` (tilde expanded), or nil when not running isolated.
    public static func supportDirectoryOverride(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let raw = environment[supportDirectory]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
        return (absolute as NSString).standardizingPath
    }

    public static func isSyncDisabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        isSet(environment[syncDisabled])
    }

    public static func syncPortSetting(environment: [String: String] = ProcessInfo.processInfo.environment) -> SyncPortSetting {
        guard let raw = environment[syncPort]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return .unset }
        guard let port = UInt16(raw), port != 0 else { return .invalid(String(raw.prefix(32))) }
        return .port(port)
    }

    public static func isBonjourDisabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        isSet(environment[syncNoBonjour])
    }

    public static func isBluetoothDisabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        isSet(environment[syncNoBluetooth])
    }

    private static func isSet(_ flag: String?) -> Bool {
        guard let value = flag?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return ["1", "true", "yes"].contains(value)
    }

    /// `$CMDS_SUPPORT_DIR/cmds.sock`, else `$CMDS_SOCKET_PATH`, else `~/Library/Application Support/cmds/cmds.sock`.
    /// `CMDS_SUPPORT_DIR` wins because `CMDS_SOCKET_PATH` is inherited inside every cmds terminal: a test
    /// instance (or its CLI) started from a terminal of the live app must never use the live socket.
    public static func defaultSocketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if supportDirectoryOverride(environment: environment) == nil, let path = environment[socketPath], !path.isEmpty {
            return path
        }
        return supportDirectoryURL(environment: environment).appendingPathComponent("cmds.sock").path
    }
}
