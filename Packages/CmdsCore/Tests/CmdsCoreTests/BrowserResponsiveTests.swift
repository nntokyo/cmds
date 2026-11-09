import Foundation
import XCTest
@testable import CmdsCore

/// The responsive view's settings, requests and scroll math (#170).
final class BrowserResponsiveTests: XCTestCase {
    func testDefaultsAndValidation() throws {
        XCTAssertEqual(BrowserResponsive().devices, ["iphone", "ipad", "desktop-1440"])
        XCTAssertTrue(BrowserResponsive().scrollSynced)
        XCTAssertEqual(try BrowserResponsive(devices: ["iPhone_SE", "800X600"], syncScroll: true).validated(),
                       BrowserResponsive(devices: ["iphone-se", "800x600"]))
        XCTAssertEqual(try BrowserResponsive(devices: ["iphone", "ipad"], syncScroll: false).validated().syncScroll, false)
        for devices in [["iphone"], ["iphone", "ipad", "pixel", "iphone-se", "desktop-1280"], ["iphone", "nokia"], ["iphone", "10x10"]] {
            XCTAssertThrowsError(try BrowserResponsive(devices: devices).validated(), "\(devices)")
        }
    }

    func testCodingKeepsOnlyWhatIsSet() throws {
        let data = try JSONEncoder().encode(BrowserResponsive(devices: ["iphone", "ipad"]))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"devices":["iphone","ipad"]}"#)
        XCTAssertEqual(try JSONDecoder().decode(BrowserResponsive.self, from: Data(#"{"devices":["a","b"],"syncScroll":false,"later":1}"#.utf8)),
                       BrowserResponsive(devices: ["a", "b"], syncScroll: false))
    }

    func testChange() throws {
        XCTAssertEqual(try BrowserResponsiveChange(params: nil), BrowserResponsiveChange())
        XCTAssertEqual(try BrowserResponsiveChange(params: ["devices": "iphone, ipad", "pane": "p1"]).devices, ["iphone", "ipad"])
        let change = BrowserResponsiveChange(on: true, devices: ["pixel", "ipad"], syncScroll: false)
        XCTAssertEqual(try BrowserResponsiveChange(params: .object(change.params.compactMapValues { $0 })), change)
        for bad: JSONValue in [["on": "yes"], ["devices": ["iphone"]], ["devices": 3], ["syncScroll": 1],
                               ["on": false, "devices": ["iphone", "ipad"]]] {
            XCTAssertThrowsError(try BrowserResponsiveChange(params: bad), "\(bad)")
        }
        // Applying.
        XCTAssertNil(try BrowserResponsiveChange().applied(to: nil))
        XCTAssertEqual(try BrowserResponsiveChange(on: true).applied(to: nil), BrowserResponsive())
        let current = BrowserResponsive(devices: ["iphone", "ipad"])
        XCTAssertEqual(try BrowserResponsiveChange().applied(to: current), current)
        XCTAssertNil(try BrowserResponsiveChange(on: false).applied(to: current))
        XCTAssertEqual(try BrowserResponsiveChange(syncScroll: false).applied(to: current)?.syncScroll, false)
        XCTAssertEqual(try BrowserResponsiveChange(devices: ["pixel", "desktop-1920"]).applied(to: nil)?.devices,
                       ["pixel", "desktop-1920"])
    }

    func testJSONAndSummary() {
        XCTAssertEqual(BrowserResponsive.summary(BrowserResponsive().json), "responsive view: iphone, ipad, desktop-1440")
        XCTAssertEqual(BrowserResponsive.summary(BrowserResponsive(devices: ["a", "b"], syncScroll: false).json),
                       "responsive view: a, b (scrolling not synced)")
        XCTAssertEqual(BrowserResponsive.summary(BrowserResponsive.offJSON), "responsive view off")
    }

    func testProportionalScroll() {
        // Half way down a phone page (3600 tall, 852 high) is half way down a desktop one (2400 tall, 900 high).
        let fraction = ResponsiveScroll.fraction(scrollY: 1374, documentHeight: 3600, viewportHeight: 852)
        XCTAssertEqual(fraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(ResponsiveScroll.scrollY(fraction: fraction, documentHeight: 2400, viewportHeight: 900), 750, accuracy: 0.5)
        XCTAssertEqual(ResponsiveScroll.fraction(scrollY: 100, documentHeight: 500, viewportHeight: 800), 0)
        XCTAssertEqual(ResponsiveScroll.fraction(scrollY: 5000, documentHeight: 1000, viewportHeight: 500), 1)
        XCTAssertEqual(ResponsiveScroll.scrollY(fraction: 2, documentHeight: 1000, viewportHeight: 500), 500)
        XCTAssertTrue(ResponsiveScroll.frameScript.contains("cmdsResponsiveScroll"))
    }

    func testBundleKey() throws {
        func bundle(_ pane: WorkspaceBundle.Pane) -> WorkspaceBundle { WorkspaceBundle(workspaces: [.init(layout: .pane(pane))]) }
        let pane = WorkspaceBundle.Pane(kind: .browser, url: "http://localhost:3000",
                                        responsive: BrowserResponsive(devices: ["iphone", "desktop-1440"]))
        let read = try WorkspaceBundle.read(try JSONEncoder().encode(bundle(pane)))
        XCTAssertEqual(read.workspaces[0].panes[0].responsive?.devices, ["iphone", "desktop-1440"])
        XCTAssertThrowsError(try bundle(WorkspaceBundle.Pane(kind: .browser, responsive: BrowserResponsive(devices: ["x", "y"]))).validated())
        XCTAssertThrowsError(try bundle(WorkspaceBundle.Pane(kind: .preview, path: "/a.md", responsive: BrowserResponsive())).validated())
    }
}
