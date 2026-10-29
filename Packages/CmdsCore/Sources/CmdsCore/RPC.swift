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

/// Environment variables injected into every terminal the app spawns.
public enum CmdsEnv {
    public static let socketPath = "CMDS_SOCKET_PATH"
    public static let workspaceID = "CMDS_WORKSPACE_ID"
    public static let paneID = "CMDS_PANE_ID"

    /// `~/Library/Application Support/cmds/cmds.sock`, overridable with `CMDS_SOCKET_PATH`.
    public static func defaultSocketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let path = environment[socketPath], !path.isEmpty { return path }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/cmds", isDirectory: true)
        return base.appendingPathComponent("cmds.sock").path
    }
}
