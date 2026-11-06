import XCTest
@testable import CmdsCore

/// Unpairing one device against an isolated instance (#114; docs/internals/testing.md "Sync against an isolated
/// instance"): set `CMDS_REVOKE_E2E_PAIRING` to its `sync-test-pairing.txt`. Two phones pair; revoking one through the
/// socket disconnects only that one, which cannot come back with its token, while the other keeps its session.
final class SyncRevokeTests: XCTestCase {
    func testRevokingOneDeviceKeepsTheOthers() throws {
        let instance = try SyncE2EInstance(pairingVariable: "CMDS_REVOKE_E2E_PAIRING")
        let suffix = UUID().uuidString.prefix(8)
        defer {  // also after a failure: leave no test devices paired
            let devices = (try? instance.api.call("sync.devices").decode([SyncPairedDevice].self)) ?? []
            for device in devices where device.name.hasSuffix(String(suffix)) {
                _ = try? instance.api.call("sync.revoke", params: ["id": .string(device.id)])
            }
        }
        let kept = try SyncE2EPhone(instance, hello: .init(deviceName: "revoke test kept \(suffix)",
                                                           deviceID: "revoke-kept-\(suffix)",
                                                           pairingCode: instance.payload.code))
        // A code pairs once: the instance writes the next one to the same file.
        var next = try SyncE2EInstance(pairingVariable: "CMDS_REVOKE_E2E_PAIRING")
        let deadline = Date().addingTimeInterval(10)
        while next.payload.code == instance.payload.code, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            next = try SyncE2EInstance(pairingVariable: "CMDS_REVOKE_E2E_PAIRING")
        }
        let revoked = try SyncE2EPhone(next, hello: .init(deviceName: "revoke test gone \(suffix)",
                                                          deviceID: "revoke-gone-\(suffix)",
                                                          pairingCode: next.payload.code))
        let devices = try instance.api.call("sync.devices").decode([SyncPairedDevice].self)
        let gone = try XCTUnwrap(devices.first { $0.name == "revoke test gone \(suffix)" })
        XCTAssertFalse(gone.connectedFrom.isEmpty, "the phone to revoke is connected")
        XCTAssertNotNil(devices.first { $0.name == "revoke test kept \(suffix)" })

        try instance.api.call("sync.revoke", params: ["id": .string(gone.id)])

        // The revoked phone gets invalidToken at once, and its token no longer opens a session.
        XCTAssertEqual(try revoked.nextError(), .invalidToken)
        XCTAssertThrowsError(try SyncE2EPhone(instance, hello: .init(deviceName: "revoke test gone \(suffix)",
                                                                     token: revoked.welcome.token))) { error in
            XCTAssertTrue("\(error)".contains("invalidToken"), "\(error)")
        }

        // The other phone still has its session: it can subscribe and gets a reply, and stays in the list.
        let after = try instance.api.call("sync.devices").decode([SyncPairedDevice].self)
        XCTAssertNil(after.first { $0.id == gone.id })
        XCTAssertNotNil(after.first { $0.name == "revoke test kept \(suffix)" })
        let reconnect = try SyncE2EPhone(instance, hello: .init(deviceName: "revoke test kept \(suffix)",
                                                                token: kept.welcome.token))
        XCTAssertFalse(reconnect.welcome.macName.isEmpty, "the kept device's token still works")

        // Unknown ids are refused, never a guess.
        XCTAssertThrowsError(try instance.api.call("sync.revoke", params: ["id": "no-such-device"]))
    }
}
