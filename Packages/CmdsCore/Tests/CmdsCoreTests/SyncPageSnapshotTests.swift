import Foundation
import XCTest
@testable import CmdsCore

/// Pictures of a browser pane's page for the phone (`SyncFeature.pageSnapshots`, #174 G25).
final class SyncPageSnapshotTests: XCTestCase {
    func testRequestAndAnswerRoundTrip() throws {
        let codec = SyncCodec()
        let request = ClientMessage.requestFile(.init(paneID: "p4", snapshot: "iphone"))
        XCTAssertEqual(try codec.decodeClientMessage(try codec.encode(request)), request)
        let piece = ServerMessage.file(.init(paneID: "p4", name: "iphone.png", mime: "image/png", size: 3, data: Data([1, 2, 3]),
                                             snapshot: "iphone"))
        XCTAssertEqual(try codec.decodeServerMessage(try codec.encode(piece)), piece)
    }

    func testOlderMessagesHaveNoSnapshot() throws {
        let codec = SyncCodec()
        let old = try codec.decodeClientMessage(Data(#"{"type":"requestFile","paneID":"p1"}"#.utf8))
        guard case .requestFile(let request) = old else { return XCTFail() }
        XCTAssertNil(request.snapshot)
        let plain = String(decoding: try codec.encode(.requestFile(.init(paneID: "p1"))), as: UTF8.self)
        XCTAssertFalse(plain.contains("snapshot"), "a preview request stays as older Macs know it")
    }

    func testChoices() {
        XCTAssertEqual(SyncPageSnapshot.choices, ["pane", "iphone", "ipad", "desktop-1440"])
        XCTAssertTrue(SyncPageSnapshot.choices.allSatisfy(SyncPageSnapshot.isValid))
        XCTAssertFalse(SyncPageSnapshot.isValid("../etc"))
        XCTAssertEqual(SyncPageSnapshot.fileName("ipad"), "ipad.png")
    }
}
