import XCTest
@testable import CmdsCore

/// Which device `cmds sync revoke` means (#114): never a guess.
final class SyncPairedDeviceTests: XCTestCase {
    private let devices = [
        SyncPairedDevice(id: "A1B2C3D4-0000", name: "iPhone-R", pairedAt: "2026-10-30T12:00:00Z", lastSeen: nil, connectedFrom: []),
        SyncPairedDevice(id: "A1B2FFFF-1111", name: "iPad", pairedAt: "2026-11-01T08:00:00Z", lastSeen: nil, connectedFrom: ["192.168.1.20"]),
        SyncPairedDevice(id: "E5F60000-2222", name: "ipad", pairedAt: "2026-11-02T08:00:00Z", lastSeen: nil, connectedFrom: []),
    ]

    func testExactIdNameOrUniquePrefix() throws {
        XCTAssertEqual(try SyncPairedDevice.match("A1B2FFFF-1111", in: devices).name, "iPad")
        XCTAssertEqual(try SyncPairedDevice.match("iphone-r", in: devices).id, "A1B2C3D4-0000")
        XCTAssertEqual(try SyncPairedDevice.match("e5f6", in: devices).id, "E5F60000-2222")
    }

    func testAmbiguousOrUnknownIsRefused() {
        XCTAssertThrowsError(try SyncPairedDevice.match("iPad", in: devices)) {  // two devices named iPad / ipad
            XCTAssertEqual($0 as? SyncPairedDevice.MatchError, .ambiguous("iPad", ["A1B2FFFF-1111", "E5F60000-2222"]))
        }
        XCTAssertThrowsError(try SyncPairedDevice.match("A1B2", in: devices))  // prefix of two ids
        XCTAssertThrowsError(try SyncPairedDevice.match("A1B", in: devices))   // prefixes need 4 characters
        XCTAssertThrowsError(try SyncPairedDevice.match("Pixel", in: devices)) {
            XCTAssertEqual($0 as? SyncPairedDevice.MatchError, .none("Pixel"))
        }
        XCTAssertThrowsError(try SyncPairedDevice.match("x", in: []))
    }
}
