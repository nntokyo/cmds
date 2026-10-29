import Foundation

/// Blocking client for the app's Unix-socket JSON-lines API (see `RPC.swift`).
/// Not thread-safe; use one client per thread.
public final class CmdsClient {
    public enum ClientError: Error, CustomStringConvertible {
        /// The app is not running (no socket or nobody listening).
        case notRunning(path: String, reason: String)
        case connectionClosed
        case timedOut
        case invalidResponse(String)
        case io(String)

        public var description: String {
            switch self {
            case .notRunning(let path, let reason): return "cannot connect to cmds at \(path) (\(reason)); is the app running?"
            case .connectionClosed: return "connection closed by cmds"
            case .timedOut: return "timed out waiting for cmds"
            case .invalidResponse(let detail): return "invalid response from cmds: \(detail)"
            case .io(let detail): return detail
            }
        }
    }

    public let socketPath: String
    private(set) var fd: Int32
    private var buffer = JSONLineBuffer()
    private var pendingLines: [Data] = []
    private var pendingEvents: [RPCEvent] = []
    private var nextID = 1

    /// Connects immediately. `timeout` bounds each wait for a response (`nil` = wait forever).
    public init(socketPath: String = CmdsEnv.defaultSocketPath(), timeout: TimeInterval? = 60) throws {
        self.socketPath = socketPath
        fd = try UnixSocket.makeStreamSocket()
        do {
            try UnixSocket.connect(fd, path: socketPath)
        } catch let failure as UnixSocket.Failure {
            Darwin.close(fd)
            throw ClientError.notRunning(path: socketPath, reason: String(cString: strerror(failure.code)))
        }
        UnixSocket.setReceiveTimeout(fd, timeout)
    }

    deinit { close() }

    public func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    /// Changes the per-read timeout (`nil` = block forever, e.g. for event streams).
    public func setTimeout(_ timeout: TimeInterval?) {
        UnixSocket.setReceiveTimeout(fd, timeout)
    }

    /// Sends a request and waits for its response. Throws `RPCError` for API errors.
    /// Events that arrive meanwhile are queued for `nextEvent()`.
    @discardableResult
    public func call(_ method: String, params: JSONValue? = nil) throws -> JSONValue {
        let id = nextID
        nextID += 1
        try send(RPCRequest(id: id, method: method, params: params))
        while true {
            let line = try nextLine()
            let object = try decodeObject(line)
            if object["event"] != nil {
                if let event = try? JSONDecoder().decode(RPCEvent.self, from: line) { pendingEvents.append(event) }
                continue
            }
            // id 0 = the server could not parse a request; anything else belongs to an older request.
            if let responseID = object["id"]?.intValue, responseID != id, responseID != 0 { continue }
            let response: RPCResponse
            do {
                response = try JSONDecoder().decode(RPCResponse.self, from: line)
            } catch {
                if let error = object["error"], let decoded = try? error.decode(RPCError.self) { throw decoded }
                throw ClientError.invalidResponse(String(decoding: line, as: UTF8.self))
            }
            if let error = response.error { throw error }
            return response.result ?? .null
        }
    }

    /// Blocks until the next pushed event. Returns nil when the server closes the connection.
    public func nextEvent() throws -> RPCEvent? {
        if !pendingEvents.isEmpty { return pendingEvents.removeFirst() }
        while true {
            let line: Data
            do { line = try nextLine() } catch ClientError.connectionClosed { return nil }
            if let event = try? JSONDecoder().decode(RPCEvent.self, from: line) { return event }
        }
    }

    // MARK: - Internals

    private func send(_ request: RPCRequest) throws {
        guard fd >= 0 else { throw ClientError.connectionClosed }
        do {
            try UnixSocket.writeAll(fd, try JSONLineBuffer.encodeLine(request))
        } catch let failure as UnixSocket.Failure {
            throw failure.code == EPIPE ? ClientError.connectionClosed : ClientError.io(failure.description)
        }
    }

    private func nextLine() throws -> Data {
        while pendingLines.isEmpty {
            guard fd >= 0 else { throw ClientError.connectionClosed }
            let chunk: Data
            do {
                chunk = try UnixSocket.read(fd)
            } catch let failure as UnixSocket.Failure {
                if failure.code == EAGAIN || failure.code == EWOULDBLOCK { throw ClientError.timedOut }
                if failure.code == ECONNRESET { throw ClientError.connectionClosed }
                throw ClientError.io(failure.description)
            }
            if chunk.isEmpty { throw ClientError.connectionClosed }
            do {
                pendingLines.append(contentsOf: try buffer.append(chunk))
            } catch {
                throw ClientError.invalidResponse("\(error)")
            }
        }
        return pendingLines.removeFirst()
    }

    private func decodeObject(_ line: Data) throws -> JSONValue {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: line), case .object = value else {
            throw ClientError.invalidResponse(String(decoding: line.prefix(200), as: UTF8.self))
        }
        return value
    }
}
