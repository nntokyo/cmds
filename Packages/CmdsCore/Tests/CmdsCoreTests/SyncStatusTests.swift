import Foundation
import XCTest
@testable import CmdsCore

/// `sync.status` / `cmds sync` result (docs/SYNC.md "Testing on a device").
final class SyncStatusTests: XCTestCase {
    func testPathFromPeerLabel() {
        XCTAssertEqual(SyncStatusReport.Client.path(forPeer: "192.168.1.20"), "network")
        XCTAssertEqual(SyncStatusReport.Client.path(forPeer: "fe80::1"), "network")
        XCTAssertEqual(SyncStatusReport.Client.path(forPeer: SyncBluetooth.peerHostPrefix + "1a2b3c4d"), "bluetooth")
        XCTAssertEqual(SyncStatusReport.Client.path(forPeer: SyncRemote.peerHostPrefix + "home"), "ssh")
    }

    func testRoundTripsThroughJSONValue() throws {
        let report = SyncStatusReport(
            enabled: true, state: "Listening on port 47999", port: 47_999, fingerprint: "AB12 CD34",
            bonjour: .init(enabled: false, serviceName: nil), pairingWindowOpen: false, pairedDevices: 1,
            bluetooth: .init(allowed: true, disabledByEnvironment: false, authorization: "allowedAlways",
                             managerState: "poweredOn", advertising: true, psm: 192, channels: 1, status: "Advertising (PSM 192)"),
            remote: .init(enabled: false, host: "", relayPort: SyncRemote.defaultRelayPort, forwarding: false, status: "Off"),
            clients: [.init(deviceName: "iPhone", authenticated: true, peer: "bluetooth:1a2b3c4d", path: "bluetooth",
                            subscribedPanes: 2, bytesSent: 12_345, bytesReceived: 678,
                            connectedSince: "2026-10-30T01:02:03Z", connectedSeconds: 42)])
        let json = try JSONValue.from(report)
        XCTAssertEqual(json["bluetooth"]?["authorization"]?.stringValue, "allowedAlways")
        guard case .array(let clients)? = json["clients"] else { return XCTFail("clients is not an array") }
        XCTAssertEqual(clients.first?["peer"]?.stringValue, "bluetooth:1a2b3c4d")
        XCTAssertEqual(try json.decode(SyncStatusReport.self), report)
    }
}
