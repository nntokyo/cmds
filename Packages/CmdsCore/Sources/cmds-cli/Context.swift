import CmdsCore
import Foundation

/// Per-invocation state handed to a command: parsed arguments, environment and the socket connection.
struct Context {
    let args: Arguments
    let environment: [String: String]

    var json: Bool { args.has("json") }

    var socketPath: String {
        if let path = args[option: "socket"], !path.isEmpty { return (path as NSString).expandingTildeInPath }
        return CmdsEnv.defaultSocketPath(environment: environment)
    }

    /// `CMDS_PANE_ID` of the terminal we run in (nil outside cmds).
    var envPane: String? { nonEmpty(environment[CmdsEnv.paneID]) }
    var envWorkspace: String? { nonEmpty(environment[CmdsEnv.workspaceID]) }

    /// `--pane` if given, else the pane we run in.
    var pane: String? { args[option: "pane"] ?? envPane }
    /// `--workspace` if given, else the workspace we run in.
    var workspace: String? { args[option: "workspace"] ?? envWorkspace }

    func connect(timeout: TimeInterval? = 60) throws -> CmdsClient {
        do {
            return try CmdsClient(socketPath: socketPath, timeout: timeout)
        } catch let error as CmdsClient.ClientError {
            throw CLIError(message: error.description, code: .unavailable)
        }
    }

    /// One request on a fresh connection. API errors become exit code 1.
    @discardableResult
    func call(_ method: String, _ params: [String: JSONValue?] = [:], timeout: TimeInterval? = 60) throws -> JSONValue {
        let client = try connect(timeout: timeout)
        defer { client.close() }
        return try perform { try client.call(method, params: object(params)) }
    }

    /// Prints `value` as JSON (pretty unless `compact`).
    func printJSON(_ value: JSONValue, compact: Bool = false) {
        print(encodeJSON(value, pretty: !compact))
    }
}

/// Maps client/API errors to CLI errors.
func perform<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let error as RPCError {
        throw CLIError.failure(error.message)
    } catch let error as CmdsClient.ClientError {
        if case .notRunning = error { throw CLIError(message: error.description, code: .unavailable) }
        throw CLIError.failure(error.description)
    }
}

/// Builds a params object, dropping nil values.
func object(_ pairs: [String: JSONValue?]) -> JSONValue? {
    let values = pairs.compactMapValues { $0 }
    return values.isEmpty ? nil : .object(values)
}

func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

func encodeJSON(_ value: JSONValue, pretty: Bool) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else { return "null" }
    return String(decoding: data, as: UTF8.self)
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data("cmds: \(message)\n".utf8))
}

/// Reads all of stdin as UTF-8.
func readStandardInput() -> String {
    String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
}

extension Optional where Wrapped == String {
    var json: JSONValue? { map { .string($0) } }
}
