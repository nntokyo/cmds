import Foundation
import XCTest
@testable import CmdsCore

/// Device sizes, user agents and color scheme of browser panes (#168).
final class BrowserDeviceTests: XCTestCase {
    func testPresets() throws {
        let ids = DevicePreset.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "unique ids")
        XCTAssertEqual(ids, ["iphone-se", "iphone", "iphone-pro-max", "pixel", "ipad", "ipad-landscape",
                             "desktop-1280", "desktop-1440", "desktop-1920"])
        for preset in DevicePreset.all {
            XCTAssertNoThrow(try preset.size.validate(), preset.id)
            XCTAssertEqual(DevicePreset.named(preset.id), preset)
            XCTAssertEqual(DevicePreset.named(preset.name), preset, "by name: \(preset.name)")
            if preset.category == .phone { XCTAssertFalse(preset.size.isLandscape, preset.id) }
            if preset.category == .desktop { XCTAssertNil(preset.userAgent, preset.id) }
        }
        XCTAssertEqual(DevicePreset.named("iPhone_SE")?.size, ViewportSize(width: 375, height: 667))
        XCTAssertEqual(DevicePreset.named("ipad-landscape")?.size, DevicePreset.named("ipad")?.size.rotated)
        XCTAssertNil(DevicePreset.named("nokia"))
        XCTAssertEqual(DevicePreset.responsiveSet.map(\.category), [.phone, .tablet, .desktop])
        XCTAssertTrue(DevicePreset.named("pixel")?.userAgent?.contains("Android") == true)
    }

    func testSizeParsing() throws {
        XCTAssertEqual(try ViewportSize.parse("390x844"), ViewportSize(width: 390, height: 844))
        XCTAssertEqual(try ViewportSize.parse(" 1024 × 768 "), ViewportSize(width: 1024, height: 768))
        XCTAssertEqual(try ViewportSize.parse("320X480"), ViewportSize(width: 320, height: 480))
        XCTAssertNil(try ViewportSize.parse("iphone"))
        XCTAssertNil(try ViewportSize.parse("390x"))
        XCTAssertNil(try ViewportSize.parse("1x2x3"))
        XCTAssertThrowsError(try ViewportSize.parse("50x800"))
        XCTAssertThrowsError(try ViewportSize.parse("390x10000"))
        XCTAssertEqual(ViewportSize(width: 390, height: 844).description, "390×844")
    }

    func testScaleToFit() {
        let desktop = ViewportSize(width: 1920, height: 1080)
        XCTAssertEqual(desktop.scaleToFit(width: 960, height: 2000), 0.5)
        XCTAssertEqual(desktop.scaleToFit(width: 3000, height: 540), 0.5)
        XCTAssertEqual(ViewportSize(width: 375, height: 667).scaleToFit(width: 800, height: 900), 1)
        XCTAssertEqual(desktop.scaleToFit(width: 0, height: 0), 1)
    }

    func testChangeFromParams() throws {
        XCTAssertTrue(try BrowserViewportChange(params: nil).isEmpty)
        XCTAssertTrue(try BrowserViewportChange(params: ["pane": "p2"]).isEmpty)
        XCTAssertEqual(try BrowserViewportChange(params: ["device": "iphone-se"]).size,
                       .preset(try XCTUnwrap(DevicePreset.named("iphone-se"))))
        XCTAssertEqual(try BrowserViewportChange(params: ["device": "800x600"]).size,
                       .custom(ViewportSize(width: 800, height: 600)))
        XCTAssertEqual(try BrowserViewportChange(params: ["width": 800, "height": 600]).size,
                       .custom(ViewportSize(width: 800, height: 600)))
        XCTAssertEqual(try BrowserViewportChange(params: ["device": "off"]).size, .fill)
        let full = try BrowserViewportChange(params: ["rotate": true, "userAgent": "", "colorScheme": "dark"])
        XCTAssertEqual(full, BrowserViewportChange(rotate: true, userAgent: "", colorScheme: .dark))
        // Every request the CLI and MCP send reads back the same.
        for change in [full, BrowserViewportChange(size: .fill), BrowserViewportChange(size: .custom(.init(width: 300, height: 500))),
                       BrowserViewportChange(size: .preset(DevicePreset.all[3]), userAgent: "x", colorScheme: .system)] {
            XCTAssertEqual(try BrowserViewportChange(params: .object(change.params.compactMapValues { $0 })), change)
        }
        for bad: JSONValue in [["device": "nokia"], ["width": 300], ["device": "iphone", "width": 300, "height": 400],
                               ["width": 300.5, "height": 400], ["width": 30, "height": 400], ["rotate": "yes"],
                               ["colorScheme": "sepia"], ["userAgent": "a\u{7}"], ["device": 3]] {
            XCTAssertThrowsError(try BrowserViewportChange(params: bad), "\(bad)") {
                XCTAssertEqual(($0 as? RPCError)?.code, -32602)
            }
        }
        XCTAssertEqual(try BrowserViewportChange.parseColorScheme("Auto"), .system)
    }

    /// The API, CLI and MCP show these messages as they are.
    func testChangeErrorMessages() {
        let presets = "iphone-se, iphone, iphone-pro-max, pixel, ipad, ipad-landscape, desktop-1280, desktop-1440, desktop-1920"
        let cases: [(JSONValue, String)] = [
            (["device": "nokia"], "unknown device \"nokia\": use a preset (\(presets)), WIDTHxHEIGHT or off"),
            (["device": 3], "device must be a string"),
            (["userAgent": 3], "userAgent must be a string"),
            (["colorScheme": true], "colorScheme must be a string"),
            (["colorScheme": "sepia"], "colorScheme must be \"light\", \"dark\" or \"system\""),
            (["width": 300.5, "height": 400], "width must be a whole number of CSS pixels"),
            (["width": 300, "height": "400"], "height must be a whole number of CSS pixels"),
            (["width": 300], "width and height go together"),
            (["device": "iphone", "width": 300, "height": 400], "give either device or width and height"),
            (["width": 30, "height": 400], "width and height must be 100–4096 CSS pixels (got 30×400)"),
            (["rotate": "yes"], "rotate must be a boolean"),
            (["userAgent": "a\u{7}"], "userAgent contains control characters"),
        ]
        for (params, message) in cases {
            XCTAssertThrowsError(try BrowserViewportChange(params: params), "\(params)") {
                XCTAssertEqual(($0 as? RPCError)?.message, message)
            }
        }
        XCTAssertThrowsError(try BrowserViewportChange(rotate: true).applied(to: BrowserEmulation())) {
            XCTAssertEqual(($0 as? RPCError)?.message, "nothing to rotate: the pane has no device size (choose one first)")
        }
    }

    func testApplying() throws {
        let iphone = try XCTUnwrap(DevicePreset.named("iphone-se"))
        var state = try BrowserViewportChange(size: .preset(iphone), colorScheme: .dark).applied(to: BrowserEmulation())
        XCTAssertEqual(state, BrowserEmulation(device: "iphone-se", size: iphone.size, userAgent: iphone.userAgent, colorScheme: .dark))
        state = try BrowserViewportChange(rotate: true).applied(to: state)
        XCTAssertEqual(state.size, ViewportSize(width: 667, height: 375))
        XCTAssertEqual(state.device, "iphone-se", "a rotated preset keeps its name")
        XCTAssertTrue(state.summary.hasPrefix("iPhone SE 667×375 (rotated)"), state.summary)
        // A custom size brings WebKit's user agent unless one is given; the scheme stays.
        state = try BrowserViewportChange(size: .custom(.init(width: 600, height: 800))).applied(to: state)
        XCTAssertEqual(state, BrowserEmulation(size: .init(width: 600, height: 800), colorScheme: .dark))
        state = try BrowserViewportChange(userAgent: "Bot/1").applied(to: state)
        XCTAssertEqual(state.userAgent, "Bot/1")
        state = try BrowserViewportChange(size: .preset(iphone), userAgent: "").applied(to: state)
        XCTAssertNil(state.userAgent)
        state = try BrowserViewportChange(size: .fill, colorScheme: .system).applied(to: state)
        XCTAssertTrue(state.isDefault)
        XCTAssertThrowsError(try BrowserViewportChange(rotate: true).applied(to: BrowserEmulation()))
    }

    /// session.json and bundles keep only what is set; older files without the key, and newer keys, read fine.
    func testCodingAndJSON() throws {
        let emulation = BrowserEmulation(device: "pixel", size: .init(width: 412, height: 915),
                                         userAgent: DevicePreset.androidUserAgent, colorScheme: .light)
        let data = try JSONEncoder().encode(emulation)
        XCTAssertEqual(try JSONDecoder().decode(BrowserEmulation.self, from: data), emulation)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(BrowserEmulation()), as: UTF8.self), "{}")
        XCTAssertEqual(try JSONDecoder().decode(BrowserEmulation.self, from: Data(#"{"colorScheme":"dark","zoom":2}"#.utf8)),
                       BrowserEmulation(colorScheme: .dark))
        XCTAssertEqual(emulation.json["width"], .number(412))
        XCTAssertEqual(BrowserEmulation().json["colorScheme"], "system")
        XCTAssertEqual(BrowserEmulation().json["device"], .null)
        XCTAssertEqual(BrowserEmulation(json: emulation.json), emulation)
        XCTAssertEqual(emulation.summary, "Pixel 7 412×915, user agent Android Chrome, color scheme light")
        XCTAssertEqual(BrowserEmulation().summary, "fills the pane, color scheme system")
        // Validation normalizes: system → nil, a device without a size dropped, empty user agent → nil.
        XCTAssertEqual(try BrowserEmulation(device: "iphone", userAgent: " ", colorScheme: .system).validated(), BrowserEmulation())
        XCTAssertThrowsError(try BrowserEmulation(userAgent: String(repeating: "a", count: 600)).validated())
    }

    func testBreakpointThresholds() {
        XCTAssertEqual(Breakpoints.thresholds(fromMediaQueries: [
            "(min-width: 768px)", "screen and (max-width: 767px)", "(min-width:1024px) and (max-width:1279.98px)",
            "(width >= 40rem)", "(width < 30em)", "(400px <= width)", "print", "(orientation: landscape)",
            "(min-device-width: 999px)", "(device-width >= 888px)", "(max-height: 500px)",
        ]), [400, 480, 640, 768, 1024, 1280])
        XCTAssertEqual(Breakpoints.thresholds(fromMediaQueries: ["(400px <= width <= 799px)"]), [400, 800])
        XCTAssertEqual(Breakpoints.thresholds(fromMediaQueries: []), [])
    }

    func testBreakpointLabel() {
        let thresholds = [640, 768, 1024, 1280]
        XCTAssertEqual(Breakpoints.label(width: 375, thresholds: thresholds), "<640")
        XCTAssertEqual(Breakpoints.label(width: 768, thresholds: thresholds), "768–1023")
        XCTAssertEqual(Breakpoints.label(width: 1023, thresholds: thresholds), "768–1023")
        XCTAssertEqual(Breakpoints.label(width: 1920, thresholds: thresholds), "≥1280")
        XCTAssertNil(Breakpoints.label(width: 800, thresholds: []))
    }
}
