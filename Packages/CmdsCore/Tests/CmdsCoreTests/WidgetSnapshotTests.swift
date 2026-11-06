import XCTest
@testable import CmdsCore

/// The file the app writes and the widget reads (#96).
final class WidgetSnapshotTests: XCTestCase {
    private func snapshot(updatedAt: TimeInterval = 1_800_000_000) -> WidgetSnapshot {
        WidgetSnapshot(updatedAt: Date(timeIntervalSince1970: updatedAt), needingUser: 1, working: 2, warning: "Claude 5h 96%",
                       workspaces: [.init(id: "w1", title: "api-server", state: .needsUser, detail: "Claude · permission",
                                          waitingSince: Date(timeIntervalSince1970: 1_799_999_820)),
                                    .init(id: "w2", title: "my-app", state: .working, detail: "Claude · tests")],
                       gauges: [.init(label: "CPU", fraction: 0.31, level: .accent),
                                .init(label: "Claude 5h", fraction: 0.96, level: .critical,
                                      resetsAt: Date(timeIntervalSince1970: 1_800_007_800))])
    }

    func testRoundTripWithStatesByName() throws {
        let data = try snapshot().encoded()
        XCTAssertEqual(try WidgetSnapshot.decode(data), snapshot())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""state":"needsUser""#), text)
        XCTAssertTrue(text.contains(#""updatedAt":1800000000"#), text)
    }

    func testUnknownStateAndFieldsFromANewerAppAreTolerated() throws {
        let json = #"{"updatedAt":1,"needingUser":0,"working":1,"workspaces":[{"id":"w","title":"t","state":"thinking","detail":"","extra":1}],"gauges":[],"future":true}"#
        let decoded = try WidgetSnapshot.decode(Data(json.utf8))
        XCTAssertEqual(decoded.workspaces.first?.state, .idle)
        XCTAssertNil(decoded.warning)
    }

    func testListIsCappedAndContentComparisonIgnoresTheTime() {
        let many = (0..<10).map { WidgetSnapshot.Workspace(id: "w\($0)", title: "\($0)", state: .working) }
        XCTAssertEqual(WidgetSnapshot(updatedAt: Date(), needingUser: 0, working: 10, workspaces: many, gauges: []).workspaces.count,
                       WidgetSnapshot.maxWorkspaces)
        XCTAssertTrue(snapshot(updatedAt: 1).sameContent(as: snapshot(updatedAt: 2)))
        var other = snapshot()
        other.working = 3
        XCTAssertFalse(snapshot().sameContent(as: other))
    }

    func testDefaultFileIsInTheRealHomesSupportFolder() {
        XCTAssertEqual(WidgetSnapshot.defaultURL(home: "/Users/someone").path,
                       "/Users/someone/Library/Application Support/cmds/widget.json")
        XCTAssertTrue(WidgetSnapshot.realHomeDirectory().hasPrefix("/"))
    }
}
