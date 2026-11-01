import Foundation
import XCTest
@testable import CmdsCore

/// `requestScrollback` and the history stream (`SyncFeature.scrollbackStream`) end to end against an isolated instance
/// (docs/internals/testing.md "Sync against an isolated instance"): set `CMDS_SCROLLBACK_E2E_PAIRING` to its
/// `sync-test-pairing.txt`. Each test opens its own workspace through the instance's socket next to that file, prints
/// numbered lines there, pairs over the pinned TLS WebSocket and checks the rows above the screen. It types only into
/// the pane it created and closes that workspace at the end.
final class SyncScrollbackTests: XCTestCase {
    func testScrollbackFromIsolatedInstance() throws {
        let instance = try Instance()
        // More lines than SyncScrollback.maxLines fit above any screen.
        let (workspaceID, paneID) = try instance.createWorkspace(title: "scrollback e2e")
        defer { instance.closeWorkspace(workspaceID) }
        try instance.type("seq 1 1500\n", into: paneID)

        // A phone without the stream (0.3.0).
        let phone = try Phone(instance, hello: .init(deviceName: "scrollback test", deviceID: "scrollback-test",
                                                     pairingCode: instance.payload.code))
        XCTAssertEqual(phone.welcome.features?.contains(SyncFeature.scrollback), true)
        try phone.send(.subscribe(.init(paneIDs: [paneID])))
        try phone.wait(for: paneID) { $0.lines.contains("1500") }

        // 100 rows: a full screen and then the rows above it under its seq.
        try phone.send(.requestScrollback(.init(paneID: paneID, lines: 100)))
        let (screen, rows) = try phone.scrollback(paneID)
        XCTAssertEqual(rows.count, 100)
        assertNumbers(rows, endRightAbove: screen)

        // More than the limit: at most SyncScrollback.maxLines. The 7-row request right after it is ignored.
        Thread.sleep(forTimeInterval: 0.6)
        try phone.send(.requestScrollback(.init(paneID: paneID, lines: 5000)))
        try phone.send(.requestScrollback(.init(paneID: paneID, lines: 7)))
        let (bigScreen, bigRows) = try phone.scrollback(paneID)
        XCTAssertGreaterThan(bigScreen.seq, screen.seq)
        XCTAssertEqual(bigRows.count, SyncScrollback.maxLines)
        assertNumbers(bigRows, endRightAbove: bigScreen)

        // At least one row. Being the next answer, it also shows that the 7-row request got none.
        Thread.sleep(forTimeInterval: 0.6)
        try phone.send(.requestScrollback(.init(paneID: paneID, lines: 0)))
        let (oneScreen, oneRow) = try phone.scrollback(paneID)
        XCTAssertEqual(oneRow.count, 1, "a request within 0.5 s of the previous one is ignored")
        assertNumbers(oneRow, endRightAbove: oneScreen)

        // Unknown pane: notFound. A pane that is not subscribed: badRequest.
        try phone.send(.requestScrollback(.init(paneID: "p-none", lines: 10)))
        XCTAssertEqual(try phone.nextError(), .notFound)
        try phone.send(.subscribe(.init(paneIDs: [])))
        try phone.send(.requestScrollback(.init(paneID: paneID, lines: 10)))
        XCTAssertEqual(try phone.nextError(), .badRequest)
        XCTAssertEqual(phone.historyMessages, 0, "scrolledOff / historyReset for a phone without scrollbackStream")
    }

    /// A phone with `scrollbackStream` keeps the rows above the screen continuous from the answer on: the rows that
    /// scroll off arrive with the screen updates, in order, without a gap or a duplicate, also after a burst of output
    /// and while the screen's text does not change. `historyReset` when the scrollback is cleared (`CSI 3 J`); after it
    /// the phone gets no rows until it asks again. A phone without the feature gets neither field.
    func testScrollbackStreamFromIsolatedInstance() throws {
        let instance = try Instance()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmds-scrollback-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Numbered rows only, in steps the test releases by creating go<n>; bursts a b: 100 rows every 0.2 s.
        let script = """
        d='\(dir.path)'
        wait_for() { while [ ! -e "$d/go$1" ]; do sleep 0.05; done; }
        bursts() {
            i=$1
            while [ $i -lt $2 ]; do seq $((i * 100 + 1)) $((i * 100 + 100)); sleep 0.2; i=$((i + 1)); done
        }
        seq 1 1500
        wait_for 1; bursts 15 30
        wait_for 2; printf '\\033[3J'
        wait_for 3; seq 3001 7000
        wait_for 4; bursts 70 76
        """
        let scriptURL = dir.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        func go(_ step: Int) {
            FileManager.default.createFile(atPath: dir.appendingPathComponent("go\(step)").path, contents: nil)
        }

        let (workspaceID, paneID) = try instance.createWorkspace(title: "scrollback stream e2e")
        defer { instance.closeWorkspace(workspaceID) }
        try instance.type("sh \(scriptURL.path)\n", into: paneID)

        let phone = try Phone(instance, hello: .init(deviceName: "scrollback stream test",
                                                     deviceID: "scrollback-stream-test",
                                                     features: [SyncFeature.scrollbackStream],
                                                     pairingCode: instance.payload.code))
        XCTAssertEqual(phone.welcome.features?.contains(SyncFeature.scrollback), true)
        XCTAssertEqual(phone.welcome.features?.contains(SyncFeature.scrollbackStream), true)
        let plain = try Phone(instance, hello: .init(deviceName: "scrollback test", token: phone.welcome.token))
        for connection in [phone, plain] {
            try connection.send(.subscribe(.init(paneIDs: [paneID])))
            try connection.wait(for: paneID) { $0.lines.contains("1500") }
        }

        // The answer starts the stream; the plain phone's answer does not.
        try phone.send(.requestScrollback(.init(paneID: paneID, lines: 1000)))
        var history = try backfill(phone, paneID, rows: 1000)
        try plain.send(.requestScrollback(.init(paneID: paneID, lines: 100)))
        let (plainScreen, plainRows) = try plain.scrollback(paneID)
        assertNumbers(plainRows, endRightAbove: plainScreen)

        // 1501…3000 in bursts of 100 rows: every row that leaves the screen arrives once, in order.
        go(1)
        var resets = 0
        try follow(phone, paneID, history: &history, resets: &resets) { screen, rows in
            Self.lastNumber(screen) == 3000 && Self.meets(rows, screen)
        }
        XCTAssertEqual(resets, 0)

        // Scrollback cleared while the screen's text stays the same: historyReset, and no rows after it.
        go(2)
        try follow(phone, paneID, history: &history, resets: &resets) { _, rows in rows == nil }
        XCTAssertEqual(resets, 1)
        let messagesAtReset = phone.historyMessages

        // 4000 rows at once after a new answer (empty: the history was cleared): more rows than an answer has
        // between two updates → historyReset (or, if the updates split them, rows that still continue).
        Thread.sleep(forTimeInterval: 0.3)
        try phone.send(.requestScrollback(.init(paneID: paneID, lines: 1000)))
        history = try backfill(phone, paneID, rows: nil)
        XCTAssertEqual(phone.historyMessages, messagesAtReset, "scrolledOff / historyReset before the next answer")
        go(3)
        try follow(phone, paneID, history: &history, resets: &resets) { screen, rows in
            Self.lastNumber(screen) == 7000 && (rows == nil || Self.meets(rows, screen))
        }
        if history == nil {
            Thread.sleep(forTimeInterval: 0.6)
            try phone.send(.requestScrollback(.init(paneID: paneID, lines: 1000)))
            history = try backfill(phone, paneID, rows: 1000)
        }

        // The stream continues from the new answer.
        let resetsBefore = resets
        go(4)
        try follow(phone, paneID, history: &history, resets: &resets) { screen, rows in
            Self.lastNumber(screen) == 7600 && Self.meets(rows, screen)
        }
        XCTAssertEqual(resets, resetsBefore)

        try plain.wait(for: paneID) { Self.lastNumber($0) == 7600 }
        XCTAssertEqual(plain.historyMessages, 0, "scrolledOff / historyReset for a phone without scrollbackStream")
    }

    // MARK: - Stream checks

    /// The answer to a `requestScrollback` already sent: its rows as numbers, consecutive and ending right above its
    /// screen; `rows` = how many there must be (nil: any, also none).
    private func backfill(_ phone: Phone, _ paneID: String, rows count: Int?,
                          file: StaticString = #filePath, line: UInt = #line) throws -> [Int]? {
        let (screen, rows) = try phone.scrollback(paneID)
        if let count { XCTAssertEqual(rows.count, count, file: file, line: line) }
        if !rows.isEmpty { assertNumbers(rows, endRightAbove: screen, file: file, line: line) }
        return rows.compactMap { Int($0) }
    }

    /// Reads the phone's messages until `done`, checking each screen update of the pane against `history`, the
    /// numbers above the screen the phone keeps (nil after `historyReset`, until it asks again): rows that left the
    /// screen (`scrolledOff`) continue them exactly (no gap, no duplicate) and end right above the new screen; updates
    /// without rows may lag behind the screen but never overlap it.
    private func follow(_ phone: Phone, _ paneID: String, history: inout [Int]?, resets: inout Int,
                        file: StaticString = #filePath, line: UInt = #line,
                        until done: (ScreenSnapshot, [Int]?) -> Bool) throws {
        let deadline = Date().addingTimeInterval(60)
        while true {
            if let screen = phone.mirror[paneID], done(screen, history) { return }
            guard Date() < deadline else {
                throw Failure("timed out: screen \(phone.mirror[paneID]?.lines ?? []), rows above end with "
                              + "\(history?.last.map(String.init) ?? "nothing")")
            }
            let scrolledOff: [String]?
            let reset: Bool
            switch try phone.next() {
            case .screen(let screen) where screen.paneID == paneID:
                scrolledOff = screen.scrolledOff
                reset = screen.historyReset == true
            case .screenDiff(let diff) where diff.paneID == paneID:
                scrolledOff = diff.scrolledOff
                reset = diff.historyReset == true
            case .scrollback:
                throw Failure("scrollback without a request")
            default:
                continue
            }
            if reset {
                XCTAssertNil(scrolledOff, "rows with historyReset", file: file, line: line)
                history = nil
                resets += 1
                continue
            }
            if let scrolledOff {
                guard var rows = history else {
                    XCTFail("scrolledOff after historyReset, before a new answer", file: file, line: line)
                    continue
                }
                for text in scrolledOff {
                    guard let number = Int(text) else {
                        XCTFail("not a number: \(text)", file: file, line: line)
                        continue
                    }
                    if let last = rows.last, number != last + 1 {
                        XCTFail("rows above the screen end with \(last), the next one that left it is \(number)",
                                file: file, line: line)
                    }
                    rows.append(number)
                }
                history = rows
            }
            guard let last = history?.last, let top = phone.mirror[paneID]?.lines.first.flatMap({ Int($0) }) else {
                continue
            }
            if scrolledOff != nil {
                XCTAssertEqual(last + 1, top, "rows that left the screen do not end right above it",
                               file: file, line: line)
            } else {
                XCTAssertLessThanOrEqual(last + 1, top, "rows above the screen overlap it", file: file, line: line)
            }
        }
    }

    /// The rows above the screen end right above its first row.
    private static func meets(_ rows: [Int]?, _ screen: ScreenSnapshot) -> Bool {
        guard let last = rows?.last, let top = screen.lines.first.flatMap({ Int($0) }) else { return false }
        return last + 1 == top
    }

    /// The last number on the screen (the shell's prompt may follow it).
    private static func lastNumber(_ screen: ScreenSnapshot) -> Int? {
        screen.lines.last { Int($0) != nil }.flatMap { Int($0) }
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

    // MARK: - Instance and phones

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// The isolated instance named by `CMDS_SCROLLBACK_E2E_PAIRING` (loopback only, never the live app).
    private struct Instance {
        let payload: SyncPairingPayload
        let api: CmdsClient

        init() throws {
            guard let path = ProcessInfo.processInfo.environment["CMDS_SCROLLBACK_E2E_PAIRING"] else {
                throw XCTSkip("set CMDS_SCROLLBACK_E2E_PAIRING to an isolated instance's sync-test-pairing.txt")
            }
            payload = try SyncPairingPayload.parse(String(contentsOfFile: path, encoding: .utf8))
            let socket = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("cmds.sock")
            let live = CmdsEnv.supportDirectoryURL(environment: [:]).appendingPathComponent("cmds.sock").path
            guard payload.host == "127.0.0.1", (socket as NSString).standardizingPath != live else {
                throw Failure("only ever test against a loopback-only isolated instance")
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
    }

    /// One phone connection (pinned TLS WebSocket) with its copy of the screens.
    private final class Phone {
        private let client: WSClient
        private let codec = SyncCodec()
        private(set) var welcome = ServerMessage.Welcome(macName: "", token: "")
        private(set) var mirror = ScreenMirror()
        /// `screen` / `screenDiff` messages that carried `scrolledOff` or `historyReset`.
        private(set) var historyMessages = 0

        init(_ instance: Instance, hello: ClientMessage.Hello) throws {
            let tls = SyncTLS.clientOptions(policy: .pinned(instance.payload.fingerprint), queue: .global()) { _ in }
            client = WSClient(port: instance.payload.port, tls: tls)
            client.start()
            guard client.waitReady() == true else { throw Failure("no connection to the instance") }
            try send(.hello(hello))
            guard case .welcome(let welcome) = try next() else { throw Failure("expected welcome") }
            self.welcome = welcome
        }

        deinit { client.cancel() }

        func send(_ message: ClientMessage) throws {
            client.send(try codec.encode(message))
        }

        /// Next message from the Mac; screens go into `mirror` (a diff that does not fit asks for the screen).
        func next() throws -> ServerMessage {
            guard let data = client.receive() else { throw Failure("no message from the Mac") }
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
                guard Date() < deadline else { throw Failure("screen never got there: \(mirror[paneID]?.lines ?? [])") }
                _ = try next()
            }
        }

        /// The answer to a `requestScrollback`: the full screen sent right before the rows, under the same seq.
        func scrollback(_ paneID: String) throws -> (ServerMessage.Screen, [String]) {
            var previous: ServerMessage?
            for _ in 0..<500 {
                let message = try next()
                if case .scrollback(let scrollback) = message {
                    guard case .screen(let screen)? = previous, screen.paneID == paneID else {
                        throw Failure("scrollback did not follow a full screen of \(paneID): "
                                      + String(describing: previous))
                    }
                    XCTAssertEqual(scrollback.paneID, paneID)
                    XCTAssertEqual(scrollback.seq, screen.seq)
                    return (screen, scrollback.lines)
                }
                previous = message
            }
            throw Failure("no scrollback from the Mac")
        }

        func nextError() throws -> SyncErrorCode? {
            for _ in 0..<20 {
                if case .error(let info) = try next() { return info.code }
            }
            return nil
        }
    }
}
