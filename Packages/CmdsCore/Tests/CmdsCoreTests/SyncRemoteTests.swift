import Foundation
import XCTest
@testable import CmdsCore

/// Remote access via SSH, Mac side (docs/internals/sync-protocol.md "Remote access via SSH").
final class SyncRemoteTests: XCTestCase {
    func testSSHArgumentsForwardLoopbackOnly() {
        let settings = SyncRemote.Settings(enabled: true, host: "home", relayPort: 47_824)
        let args = SyncRemote.sshArguments(settings: settings, ingressPort: 50_123)
        XCTAssertEqual(args.suffix(2), ["--", "home"])
        let r = args.firstIndex(of: "-R").map { args[$0 + 1] }
        XCTAssertEqual(r, "127.0.0.1:47824:127.0.0.1:50123")
        for option in ["BatchMode=yes", "ExitOnForwardFailure=yes", "ServerAliveInterval=15", "ControlPath=none"] {
            XCTAssertTrue(args.contains(option), option)
        }
        XCTAssertTrue(args.contains("-N"))
        XCTAssertFalse(args.contains("-F"))
        let withConfig = SyncRemote.sshArguments(settings: settings, ingressPort: 1, configFile: "/tmp/x/ssh_config")
        XCTAssertEqual(Array(withConfig.prefix(2)), ["-F", "/tmp/x/ssh_config"])
    }

    func testHostValidation() {
        XCTAssertTrue(SyncRemote.isValidHost("home"))
        XCTAssertTrue(SyncRemote.isValidHost("me@relay.example.com"))
        XCTAssertFalse(SyncRemote.isValidHost(""))
        XCTAssertFalse(SyncRemote.isValidHost("-oProxyCommand=evil"))
        XCTAssertFalse(SyncRemote.isValidHost("host; rm -rf ~"))
        XCTAssertFalse(SyncRemote.isValidHost("a@b@c"))
        XCTAssertFalse(SyncRemote.Settings(enabled: true, host: "", relayPort: 1).isActive)
        XCTAssertFalse(SyncRemote.Settings(enabled: false, host: "home").isActive)
        XCTAssertTrue(SyncRemote.Settings(enabled: true, host: "home").isActive)
    }

    func testSettingsDecodeDefaults() throws {
        let decoded = try JSONDecoder().decode(SyncRemote.Settings.self, from: Data(#"{"enabled":true,"host":"h","relayPort":5}"#.utf8))
        XCTAssertEqual(decoded, SyncRemote.Settings(enabled: true, host: "h", relayPort: 5))
    }

    func testRestartBackoff() {
        XCTAssertEqual(SyncRemote.restartDelay(failures: 0), 2)
        XCTAssertEqual(SyncRemote.restartDelay(failures: 2), 8)
        XCTAssertEqual(SyncRemote.restartDelay(failures: 100), 60)
    }

    func testIdleState() {
        XCTAssertEqual(SyncRemote.idleState(SyncRemote.Settings(enabled: false, host: "home")), .off)
        XCTAssertEqual(SyncRemote.idleState(SyncRemote.Settings(enabled: true, host: "")), .chooseHost)
        XCTAssertEqual(SyncRemote.idleState(SyncRemote.Settings(enabled: true, host: "home", relayPort: 0)), .chooseHost)
        XCTAssertEqual(SyncRemote.idleState(SyncRemote.Settings(enabled: true, host: "home")), .waitingForSync)
    }

    func testSSHRecordRoundTrip() {
        let record = SyncRemote.SSHRecord(pid: 4321, startSeconds: 1_790_000_000, startMicroseconds: 123_456)
        XCTAssertEqual(record.fileText, "4321 1790000000 123456\n")
        XCTAssertEqual(SyncRemote.SSHRecord(fileText: record.fileText), record)
    }

    func testSSHRecordRejectsPidOnlyAndMalformed() {
        // The older pid-only file carries no start time, so it never matches a process.
        XCTAssertNil(SyncRemote.SSHRecord(fileText: "4321\n"))
        XCTAssertNil(SyncRemote.SSHRecord(fileText: "1 1790000000 0\n"))
        XCTAssertNil(SyncRemote.SSHRecord(fileText: "4321 x 0\n"))
        XCTAssertNil(SyncRemote.SSHRecord(fileText: "4321 1790000000 0 9\n"))
        XCTAssertNil(SyncRemote.SSHRecord(fileText: ""))
    }

    func testRemoteSSHConfigOnlyWhenIsolated() {
        XCTAssertNil(CmdsEnv.remoteSSHConfig(environment: ["CMDS_SYNC_REMOTE_SSH_CONFIG": "/tmp/c"]))
        XCTAssertEqual(CmdsEnv.remoteSSHConfig(environment: ["CMDS_SYNC_REMOTE_SSH_CONFIG": "/tmp/c", "CMDS_SUPPORT_DIR": "/tmp/s"]), "/tmp/c")
    }

    func testLoopbackServerAcceptsEveryConnection() throws {
        let server = try SyncLoopback.Server()
        defer { server.close() }
        let accepted = expectation(description: "accepted")
        accepted.expectedFulfillmentCount = 3
        server.start { fd in
            close(fd)
            accepted.fulfill()
        }
        var fds: [Int32] = []
        for _ in 0..<3 { fds.append(try SyncLoopback.connect(port: server.port) { _ in }) }
        wait(for: [accepted], timeout: 5)
        fds.forEach { close($0) }
    }
}
