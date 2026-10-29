import XCTest
@testable import CmdsCore

final class RPCTests: XCTestCase {
    func testRequestRoundTrip() throws {
        let req = RPCRequest(id: 1, method: "pane.split", params: ["direction": "right", "ratio": 0.5])
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(RPCRequest.self, from: data)
        XCTAssertEqual(decoded.method, "pane.split")
        XCTAssertEqual(decoded.params?["direction"]?.stringValue, "right")
    }

    func testLayoutRoundTrip() throws {
        let layout = LayoutNode.split(axis: .horizontal, ratio: 0.5, first: .pane(id: "p1"), second: .pane(id: "p2"))
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(LayoutNode.self, from: data), layout)
    }
}
