import Foundation
import XCTest
@testable import CmdsCore

/// `browser.snapshot` params and answers (#169).
final class BrowserSnapshotTests: XCTestCase {
    func testPlainRequest() throws {
        XCTAssertTrue(try BrowserSnapshotRequest(params: nil).isPlain)
        XCTAssertTrue(try BrowserSnapshotRequest(params: ["pane": "p2", "workspace": "w1"]).isPlain)
        XCTAssertTrue(try BrowserSnapshotRequest(params: ["fullPage": false, "selector": nil]).isPlain)
        XCTAssertEqual(BrowserSnapshotRequest().params.count, 0)
    }

    func testParams() throws {
        let request = try BrowserSnapshotRequest(params: ["fullPage": true, "selector": " #main ", "devices": ["iphone", "800x600"]])
        XCTAssertTrue(request.fullPage)
        XCTAssertEqual(request.selector, "#main")
        XCTAssertEqual(request.targets.map(\.label), ["iphone", "800x600"])
        XCTAssertEqual(request.targets[0].size, DevicePreset.named("iphone")?.size)
        XCTAssertEqual(try BrowserSnapshotRequest(params: ["devices": "iphone, ipad"]).targets.map(\.label), ["iphone", "ipad"])
        XCTAssertEqual(try BrowserSnapshotRequest(params: ["device": "pixel"]).targets.map(\.label), ["pixel"])
        XCTAssertEqual(try BrowserSnapshotRequest(params: ["width": 700]).targets.first?.size, ViewportSize(width: 700, height: 900))
        XCTAssertEqual(try BrowserSnapshotRequest(params: ["width": 700, "height": 500]).targets.first?.label, "700x500")
        // What the CLI and MCP send reads back the same.
        for request in [request, BrowserSnapshotRequest(targets: [.init(preset: DevicePreset.all[0])]),
                        BrowserSnapshotRequest(fullPage: true), BrowserSnapshotRequest(selector: "h1")] {
            XCTAssertEqual(try BrowserSnapshotRequest(params: .object(request.params.compactMapValues { $0 })), request)
        }
        // The default set of #170 / `--device` examples.
        let responsive = try BrowserSnapshotRequest(params: .object(["devices": .array(DevicePreset.responsiveSet.map { .string($0.id) })]))
        XCTAssertEqual(responsive.targets.count, 3)
    }

    func testRefusals() {
        let bad: [JSONValue] = [
            ["zoom": 2],  // unknown: newer clients learn that this app lacks it
            ["fullPage": "yes"], ["selector": ""], ["selector": 3],
            ["selector": .string(String(repeating: "a", count: 1_001))],
            ["device": "nokia"], ["devices": []], ["devices": [1]], ["devices": ["a", "b", "c", "d", "e"]],
            ["devices": ["iphone", "ipad", "pixel", "iphone-se", "desktop-1280"]],
            ["device": "iphone", "width": 400], ["height": 500], ["width": 20], ["width": 300.5], "text",
        ]
        for params in bad {
            XCTAssertThrowsError(try BrowserSnapshotRequest(params: params), "\(params)") {
                XCTAssertEqual(($0 as? RPCError)?.code, -32602)
            }
        }
        XCTAssertThrowsError(try BrowserSnapshotRequest(params: ["zoom": 2])) {
            XCTAssertTrue(($0 as? RPCError)?.message.contains("unsupported") == true)
        }
    }

    /// The API, CLI and MCP show these messages as they are.
    func testRefusalMessages() {
        let presets = "iphone-se, iphone, iphone-pro-max, pixel, ipad, ipad-landscape, desktop-1280, desktop-1440, desktop-1920"
        let cases: [(JSONValue, String)] = [
            (["zoom": 2, "abc": 1], "browser.snapshot does not support the parameter \"abc\" (unsupported by this cmds app)"),
            ("text", "params must be an object"),
            (["fullPage": "yes"], "fullPage must be a boolean"),
            (["selector": " "], "selector is empty"),
            (["selector": .string(String(repeating: "a", count: 1_001))], "selector is too long"),
            (["selector": 3], "selector must be a string"),
            (["device": "iphone", "width": 400], "give only one of device, devices and width"),
            (["height": 500], "height goes with width"),
            (["device": 3], "device must be a string"),
            (["device": "nokia"], "unknown device \"nokia\": use a preset (\(presets)) or WIDTHxHEIGHT"),
            (["devices": [1]], "devices must be strings"),
            (["devices": []], "devices is empty"),
            (["devices": ""], "devices is empty"),
            (["devices": 3], "devices must be a list of presets or WIDTHxHEIGHT"),
            (["width": 300.5], "width must be a whole number of CSS pixels"),
            (["width": 300, "height": "x"], "height must be a whole number of CSS pixels"),
            (["width": 20], "width and height must be 100–4096 CSS pixels (got 20×900)"),
            (["devices": ["iphone", "ipad", "pixel", "iphone-se", "desktop-1280"]], "at most 4 devices per snapshot"),
        ]
        for (params, message) in cases {
            XCTAssertThrowsError(try BrowserSnapshotRequest(params: params), "\(params)") {
                XCTAssertEqual(($0 as? RPCError)?.message, message)
            }
        }
        XCTAssertEqual(BrowserSnapshotRequest.tooTall(30_000).message,
                       "the page is 30000 CSS pixels tall, over the 16384 px limit of a snapshot; capture an element (selector) instead")
    }

    func testLimits() {
        XCTAssertEqual(BrowserSnapshotRequest.outputScale(cssHeight: 4_000), 2)
        XCTAssertEqual(BrowserSnapshotRequest.outputScale(cssHeight: 4_096), 2)
        XCTAssertEqual(BrowserSnapshotRequest.outputScale(cssHeight: 4_097), 1)
        XCTAssertTrue(BrowserSnapshotRequest.tooTall(30_000).message.contains("30000"))
        XCTAssertTrue(BrowserSnapshotRequest.tooTall(30_000).message.contains("16384"))
    }

    func testAnswer() throws {
        let images = [BrowserSnapshotImage(device: "iphone", width: 393, height: 2000, png: Data([1, 2])),
                      BrowserSnapshotImage(device: nil, width: 800, height: 600, png: Data([3]))]
        let result = BrowserSnapshotImage.result(images)
        XCTAssertEqual(result["png_base64"], .string(Data([1, 2]).base64EncodedString()))
        XCTAssertEqual(BrowserSnapshotImage.images(from: result), images)
        // An app older than #169 answers with the visible page only.
        XCTAssertNil(BrowserSnapshotImage.images(from: ["png_base64": "AQI="]))
    }
}
