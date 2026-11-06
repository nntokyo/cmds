import XCTest
@testable import cmds_cli
@testable import CmdsCore

/// `cmds sync devices`: one line per paired device (#114).
final class SyncDevicesCLITests: XCTestCase {
    func testOneLinePerDevice() {
        let devices = [
            SyncPairedDevice(id: "A1B2C3D4", name: "iPhone-R", pairedAt: "2026-10-30T12:00:00Z",
                             lastSeen: "2026-11-06T13:05:44Z", connectedFrom: []),
            SyncPairedDevice(id: "E5F60000", name: "iPad", pairedAt: "2026-11-01T08:00:00Z", lastSeen: nil,
                             connectedFrom: ["192.168.1.20", "bluetooth:4F2A"]),
            SyncPairedDevice(id: "0000FFFF", name: "iPad mini", pairedAt: "2026-11-02T08:00:00Z", lastSeen: nil,
                             connectedFrom: []),
        ]
        // Times in the Mac's zone: 13:05 UTC is 22:05 in Tokyo.
        XCTAssertEqual(Format.pairedDevices(devices, timeZone: TimeZone(identifier: "Asia/Tokyo")!),
                       "A1B2C3D4  iPhone-R   last seen 2026-11-06 22:05  · paired 2026-10-30\n"
                       + "E5F60000  iPad       connected (192.168.1.20, bluetooth:4F2A)  · paired 2026-11-01\n"
                       + "0000FFFF  iPad mini  not connected  · paired 2026-11-02\n")
        XCTAssertEqual(Format.pairedDevices([devices[0]], timeZone: TimeZone(identifier: "UTC")!),
                       "A1B2C3D4  iPhone-R  last seen 2026-11-06 13:05  · paired 2026-10-30\n")
        XCTAssertEqual(Format.pairedDevices([]), "no paired devices\n")
    }
}
