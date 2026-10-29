import XCTest
@testable import CmdsCore

final class SyncCodecTests: XCTestCase {
    let codec = SyncCodec()

    func testClientMessagesRoundTrip() throws {
        let messages: [ClientMessage] = [
            .hello(.init(deviceName: "iPhone", deviceID: "dev-1", pairingCode: "012345")),
            .hello(.init(deviceName: "iPad", token: "tok")),
            .subscribe(.init(paneIDs: ["p1", "p2"])),
            .requestScreen(.init(paneID: "p1")),
            .input(.init(paneID: "p1", text: "ls -la\n日本語")),
            .key(.init(paneID: "p1", key: .ctrlC)),
            .key(.init(paneID: "p1", key: .up)),
            .selectWorkspace(.init(id: "w1")),
            .focusPane(.init(id: "p2")),
            .ping(.init()),
            .ping(.init(nonce: 7)),
        ]
        for message in messages {
            let data = try codec.encode(message)
            XCTAssertEqual(try codec.decodeClientMessage(data), message, String(decoding: data, as: UTF8.self))
            XCTAssertEqual(codec.peekType(data), message.typeName)
        }
    }

    func testServerMessagesRoundTrip() throws {
        let ws = WorkspaceInfo(id: "w1", title: "api", selected: true, gitBranch: "main", workingDirectory: "/tmp",
                               ports: [3000], notificationText: "done", attention: true,
                               panes: [PaneInfo(id: "p1", kind: .terminal, title: "zsh", focused: true, attention: false)],
                               layout: .pane(id: "p1"))
        let messages: [ServerMessage] = [
            .welcome(.init(macName: "Mac", token: "abc")),
            .error(.init(code: .invalidPairingCode, message: "nope")),
            .state(.init(workspaces: [ws])),
            .screen(.init(paneID: "p1", seq: 1, rows: 2, cols: 10, lines: ["$ ls", ""], cursorRow: 1, cursorCol: 0)),
            .screen(.init(paneID: "p1", seq: 2, rows: 1, cols: 10, lines: ["x"])),
            .screenDiff(.init(paneID: "p1", seq: 3, baseSeq: 2, changes: [.init(row: 0, text: "y")], cursorRow: 0, cursorCol: 1)),
            .notification(.init(paneID: "p1", workspaceID: "w1", title: "Claude", body: "needs input")),
            .notification(.init(paneID: nil, workspaceID: "w1", title: "t", body: "b")),
            .pong(.init(nonce: 7)),
        ]
        for message in messages {
            let data = try codec.encode(message)
            XCTAssertEqual(try codec.decodeServerMessage(data), message, String(decoding: data, as: UTF8.self))
        }
    }

    func testWireFormatIsFlatWithTypeField() throws {
        let data = try codec.encode(ClientMessage.input(.init(paneID: "p1", text: "hi")))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"paneID":"p1","text":"hi","type":"input"}"#)
        let key = try codec.encode(ClientMessage.key(.init(paneID: "p1", key: .escape)))
        XCTAssertEqual(String(decoding: key, as: UTF8.self), #"{"key":"esc","paneID":"p1","type":"key"}"#)
        let ping = try codec.encode(ClientMessage.ping(.init()))
        XCTAssertEqual(String(decoding: ping, as: UTF8.self), #"{"type":"ping"}"#)
    }

    func testDecodesHandWrittenJSON() throws {
        let json = #"{"type":"hello","protocolVersion":1,"deviceName":"phone","pairingCode":"123456","extra":true}"#
        guard case .hello(let hello) = try codec.decodeClientMessage(Data(json.utf8)) else { return XCTFail() }
        XCTAssertEqual(hello.pairingCode, "123456")
        XCTAssertNil(hello.token)

        let err = #"{"type":"error","code":"somethingNew","message":"m"}"#
        guard case .error(let info) = try codec.decodeServerMessage(Data(err.utf8)) else { return XCTFail() }
        XCTAssertEqual(info.code.rawValue, "somethingNew")
    }

    func testUnknownTypeThrows() {
        XCTAssertThrowsError(try codec.decodeServerMessage(Data(#"{"type":"bogus"}"#.utf8))) { error in
            XCTAssertEqual(error as? UnknownSyncMessageType, UnknownSyncMessageType(type: "bogus"))
        }
        XCTAssertThrowsError(try codec.decodeClientMessage(Data(#"{"paneID":"p"}"#.utf8)))
    }

    func testKeyTerminalBytes() {
        XCTAssertEqual(SyncKey.enter.terminalBytes(), [0x0D])
        XCTAssertEqual(SyncKey.ctrlC.terminalBytes(), [0x03])
        XCTAssertEqual(SyncKey.ctrl("A").terminalBytes(), [0x01])
        XCTAssertEqual(SyncKey.up.terminalBytes(), [0x1B, 0x5B, 0x41])
        XCTAssertEqual(SyncKey.up.terminalBytes(applicationCursor: true), [0x1B, 0x4F, 0x41])
        XCTAssertEqual(SyncKey.escape.terminalBytes(), [0x1B])
        XCTAssertNil(SyncKey(rawValue: "f13").terminalBytes())
    }
}
