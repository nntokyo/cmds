import Foundation
import XCTest
@testable import CmdsCore

/// Remote access via SSH, Mac side (docs/SYNC.md "Remote access via SSH").
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

    func testHostAliasesFromConfig() {
        let config = """
        Host home
            HostName 192.0.2.1
        Host *.example !bad work-box
        host=lower
        Match host foo
        Host home
        """
        XCTAssertEqual(SyncRemote.hostAliases(inConfig: config), ["home", "work-box", "lower"])
    }

    func testRestartBackoff() {
        XCTAssertEqual(SyncRemote.restartDelay(failures: 0), 2)
        XCTAssertEqual(SyncRemote.restartDelay(failures: 2), 8)
        XCTAssertEqual(SyncRemote.restartDelay(failures: 100), 60)
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
