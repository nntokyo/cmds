import Foundation
import XCTest
@testable import CmdsCore

/// `requestScrollback` end to end against an isolated instance (docs/internals/testing.md "Sync against an isolated
/// instance"): set `CMDS_SCROLLBACK_E2E_PAIRING` to its `sync-test-pairing.txt`. Opens its own workspace through the
/// instance's socket next to that file, prints numbered lines there, pairs over the pinned TLS WebSocket and checks
/// the rows above the screen. It types only into the pane it created and closes that workspace at the end.
final class SyncScrollbackTests: XCTestCase {
    private let codec = SyncCodec()
    private var mirror = ScreenMirror()

    func testScrollbackFromIsolatedInstance() throws {
        guard let path = ProcessInfo.processInfo.environment["CMDS_SCROLLBACK_E2E_PAIRING"] else {
            throw XCTSkip("set CMDS_SCROLLBACK_E2E_PAIRING to an isolated instance's sync-test-pairing.txt")
        }
        let payload = try SyncPairingPayload.parse(String(contentsOfFile: path, encoding: .utf8))
        let socket = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("cmds.sock")
        let live = CmdsEnv.supportDirectoryURL(environment: [:]).appendingPathComponent("cmds.sock").path
        guard payload.host == "127.0.0.1", (socket as NSString).standardizingPath != live else {
            return XCTFail("only ever test against a loopback-only isolated instance")
        }

        // More lines than SyncScrollback.maxLines fit above any screen.
        let api = try CmdsClient(socketPath: socket, timeout: 10)
        let workspace = try api.call("workspace.create", params: ["title": "scrollback e2e", "cwd": "/tmp"])
        let workspaceID = try XCTUnwrap(workspace["id"]?.stringValue)
        defer { _ = try? api.call("workspace.close", params: ["id": .string(workspaceID)]) }
        let paneID = try XCTUnwrap(workspace["panes"]?.arrayValue?.first?["id"]?.stringValue)
        try api.call("pane.send_text", params: ["pane": .string(paneID), "text": "seq 1 1500\n"])

        let tls = SyncTLS.clientOptions(policy: .pinned(payload.fingerprint), queue: .global()) { _ in }
        let client = WSClient(port: payload.port, tls: tls)
        client.start()
        defer { client.cancel() }
        XCTAssertEqual(client.waitReady(), true)
        client.send(try codec.encode(.hello(.init(deviceName: "scrollback test", deviceID: "scrollback-test",
                                                  pairingCode: payload.code))))
        guard case .welcome(let welcome) = try next(client) else { return XCTFail("expected welcome") }
        XCTAssertEqual(welcome.features?.contains(SyncFeature.scrollback), true)

        client.send(try codec.encode(.subscribe(.init(paneIDs: [paneID]))))
        let deadline = Date().addingTimeInterval(30)
        while mirror[paneID]?.lines.contains("1500") != true {
            guard Date() < deadline else { return XCTFail("1500 never showed up: \(mirror[paneID]?.lines ?? [])") }
            _ = try next(client)
        }

        // 100 rows: a full screen and then the rows above it under its seq.
        client.send(try codec.encode(.requestScrollback(.init(paneID: paneID, lines: 100))))
        let (screen, rows) = try scrollback(client, paneID: paneID)
        XCTAssertEqual(rows.count, 100)
        assertNumbers(rows, endRightAbove: screen)

        // More than the limit: at most SyncScrollback.maxLines. The 7-row request right after it is ignored.
        Thread.sleep(forTimeInterval: 0.6)
        client.send(try codec.encode(.requestScrollback(.init(paneID: paneID, lines: 5000))))
        client.send(try codec.encode(.requestScrollback(.init(paneID: paneID, lines: 7))))
        let (bigScreen, bigRows) = try scrollback(client, paneID: paneID)
        XCTAssertGreaterThan(bigScreen.seq, screen.seq)
        XCTAssertEqual(bigRows.count, SyncScrollback.maxLines)
        assertNumbers(bigRows, endRightAbove: bigScreen)

        // At least one row. Being the next answer, it also shows that the 7-row request got none.
        Thread.sleep(forTimeInterval: 0.6)
        client.send(try codec.encode(.requestScrollback(.init(paneID: paneID, lines: 0))))
        let (oneScreen, oneRow) = try scrollback(client, paneID: paneID)
        XCTAssertEqual(oneRow.count, 1, "a request within 0.5 s of the previous one is ignored")
        assertNumbers(oneRow, endRightAbove: oneScreen)

        // Unknown pane: notFound. A pane that is not subscribed: badRequest.
        client.send(try codec.encode(.requestScrollback(.init(paneID: "p-none", lines: 10))))
        XCTAssertEqual(try nextError(client), .notFound)
        client.send(try codec.encode(.subscribe(.init(paneIDs: []))))
        client.send(try codec.encode(.requestScrollback(.init(paneID: paneID, lines: 10))))
        XCTAssertEqual(try nextError(client), .badRequest)
    }

    // MARK: - Helpers

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Next message from the Mac; screens go into `mirror`.
    private func next(_ client: WSClient) throws -> ServerMessage {
        let message = try codec.decodeServerMessage(XCTUnwrap(client.receive(), "no message from the Mac"))
        switch message {
        case .screen(let screen): _ = mirror.apply(screen)
        case .screenDiff(let diff): _ = mirror.apply(diff)
        default: break
        }
        return message
    }

    /// The answer to a `requestScrollback`: the full screen sent right before the rows, under the same seq.
    private func scrollback(_ client: WSClient, paneID: String) throws -> (ServerMessage.Screen, [String]) {
        var previous: ServerMessage?
        for _ in 0..<100 {
            let message = try next(client)
            if case .scrollback(let scrollback) = message {
                guard case .screen(let screen)? = previous, screen.paneID == paneID else {
                    throw Failure("scrollback did not follow a full screen of \(paneID): \(String(describing: previous))")
                }
                XCTAssertEqual(scrollback.paneID, paneID)
                XCTAssertEqual(scrollback.seq, screen.seq)
                return (screen, scrollback.lines)
            }
            previous = message
        }
        throw Failure("no scrollback from the Mac")
    }

    private func nextError(_ client: WSClient) throws -> SyncErrorCode? {
        for _ in 0..<20 {
            if case .error(let info) = try next(client) { return info.code }
        }
        return nil
    }

    /// `rows` are consecutive numbers, the last one right above the screen's first row.
    private func assertNumbers(_ rows: [String], endRightAbove screen: ServerMessage.Screen,
                               file: StaticString = #filePath, line: UInt = #line) {
        let numbers = rows.compactMap { Int($0) }
        XCTAssertEqual(numbers.count, rows.count, "not all numbers: \(rows.prefix(3))…\(rows.suffix(3))", file: file, line: line)
        guard let first = numbers.first, let last = numbers.last else { return XCTFail("no rows", file: file, line: line) }
        XCTAssertEqual(numbers, Array(first...last), "not consecutive", file: file, line: line)
        XCTAssertEqual(screen.lines.first.flatMap { Int($0) }, last + 1,
                       "screen starts with \(screen.lines.prefix(2)), rows end with \(last)", file: file, line: line)
    }
}
