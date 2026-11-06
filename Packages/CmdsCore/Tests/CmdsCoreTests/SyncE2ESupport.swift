@testable import CmdsCore
import Foundation
import XCTest

// Phones against an isolated instance, for the end-to-end sync tests (SyncScrollbackTests, SyncRevokeTests;
// docs/internals/testing.md "Sync against an isolated instance").

struct SyncE2EFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The isolated instance named by an environment variable (its `sync-test-pairing.txt`; loopback only, never the live
/// app). Tests skip when the variable is not set.
struct SyncE2EInstance {
    let payload: SyncPairingPayload
    let api: CmdsClient

    init(pairingVariable: String) throws {
        guard let path = ProcessInfo.processInfo.environment[pairingVariable] else {
            throw XCTSkip("set \(pairingVariable) to an isolated instance's sync-test-pairing.txt")
        }
        payload = try SyncPairingPayload.parse(String(contentsOfFile: path, encoding: .utf8))
        let socket = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("cmds.sock")
        let live = CmdsEnv.supportDirectoryURL(environment: [:]).appendingPathComponent("cmds.sock").path
        guard payload.host == "127.0.0.1", (socket as NSString).standardizingPath != live else {
            throw SyncE2EFailure("only ever test against a loopback-only isolated instance")
        }
        api = try CmdsClient(socketPath: socket, timeout: 10)
    }

    func createWorkspace(title: String) throws -> (workspaceID: String, paneID: String) {
        let workspace = try api.call("workspace.create", params: ["title": .string(title), "cwd": "/tmp"])
        let workspaceID = try XCTUnwrap(workspace["id"]?.stringValue)
        let paneID = try XCTUnwrap(workspace["panes"]?.arrayValue?.first?["id"]?.stringValue)
        return (workspaceID, paneID)
    }

    func closeWorkspace(_ id: String) {
        _ = try? api.call("workspace.close", params: ["id": .string(id)])
    }

    func type(_ text: String, into paneID: String) throws {
        try api.call("pane.send_text", params: ["pane": .string(paneID), "text": .string(text)])
    }

    /// The first number in the pane's text (its whole scrollback and screen), nil if there is none.
    func firstNumber(in paneID: String) throws -> Int? {
        let result = try api.call("pane.read_text",
                                  params: ["pane": .string(paneID), "scrollback": .number(1_000_000)])
        let lines = (result["text"]?.stringValue ?? "").split(separator: "\n")
        return lines.lazy.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.first
    }
}

/// One phone connection (pinned TLS WebSocket) with its copy of the screens.
final class SyncE2EPhone {
    private let client: WSClient
    private let codec = SyncCodec()
    private(set) var welcome = ServerMessage.Welcome(macName: "", token: "")
    private(set) var mirror = ScreenMirror()
    /// `screen` / `screenDiff` messages that carried `scrolledOff` or `historyReset`.
    private(set) var historyMessages = 0

    init(_ instance: SyncE2EInstance, hello: ClientMessage.Hello) throws {
        let tls = SyncTLS.clientOptions(policy: .pinned(instance.payload.fingerprint), queue: .global()) { _ in }
        client = WSClient(port: instance.payload.port, tls: tls)
        client.start()
        guard client.waitReady() == true else { throw SyncE2EFailure("no connection to the instance") }
        try send(.hello(hello))
        let reply = try next()
        guard case .welcome(let welcome) = reply else { throw SyncE2EFailure("expected welcome, got \(reply)") }
        self.welcome = welcome
    }

    deinit { client.cancel() }

    func send(_ message: ClientMessage) throws {
        client.send(try codec.encode(message))
    }

    /// Next message from the Mac; screens go into `mirror` (a diff that does not fit asks for the screen).
    func next() throws -> ServerMessage {
        guard let data = client.receive() else { throw SyncE2EFailure("no message from the Mac") }
        let message = try codec.decodeServerMessage(data)
        let result: ScreenMirror.ApplyResult
        switch message {
        case .screen(let screen):
            if screen.scrolledOff != nil || screen.historyReset != nil { historyMessages += 1 }
            result = mirror.apply(screen)
        case .screenDiff(let diff):
            if diff.scrolledOff != nil || diff.historyReset != nil { historyMessages += 1 }
            result = mirror.apply(diff)
        default:
            return message
        }
        if case .needsFullScreen(let paneID) = result { try send(.requestScreen(.init(paneID: paneID))) }
        return message
    }

    /// Reads messages until the pane's screen satisfies `condition`.
    func wait(for paneID: String, timeout: TimeInterval = 30, until condition: (ScreenSnapshot) -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while mirror[paneID].map(condition) != true {
            guard Date() < deadline else { throw SyncE2EFailure("screen never got there: \(mirror[paneID]?.lines ?? [])") }
            _ = try next()
        }
    }

    /// The answer to a `requestScrollback`: the full screen sent right before the rows, under the same seq.
    func scrollback(_ paneID: String, within maxMessages: Int = 500) throws -> (ServerMessage.Screen, [String]) {
        var previous: ServerMessage?
        for _ in 0..<maxMessages {
            let message = try next()
            if case .scrollback(let scrollback) = message {
                guard case .screen(let screen)? = previous, screen.paneID == paneID else {
                    throw SyncE2EFailure("scrollback did not follow a full screen of \(paneID): "
                                  + String(describing: previous))
                }
                XCTAssertEqual(scrollback.paneID, paneID)
                XCTAssertEqual(scrollback.seq, screen.seq)
                return (screen, scrollback.lines)
            }
            previous = message
        }
        throw SyncE2EFailure("no scrollback from the Mac")
    }

    func nextError() throws -> SyncErrorCode? {
        for _ in 0..<20 {
            if case .error(let info) = try next() { return info.code }
        }
        return nil
    }
}
