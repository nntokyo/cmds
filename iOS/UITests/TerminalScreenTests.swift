import XCTest

/// Rendering checks against the `-mock` demo data (simulator only; launches the app, unlike `DeviceDriverTests`).
/// Run: `-only-testing:CmdsDeviceDriver/TerminalScreenTests` with the companion app installed on the simulator.
final class TerminalScreenTests: XCTestCase {
    /// A full-screen TUI (Claude Code: header at the top, prompt at the bottom, blank rows between) zoomed in
    /// must keep the prompt row in view. Regression: scrolling to a padded anchor view left the viewport on the
    /// blank middle rows, so the pane looked completely empty.
    func testZoomedFullScreenTUIShowsThePromptRow() throws {
        #if !targetEnvironment(simulator)
        // Never relaunch the app on a real phone: it may be connected to a Mac in use.
        throw XCTSkip("simulator only")
        #endif
        let app = XCUIApplication(bundleIdentifier: "tokyo.n-n.cmds.companion")
        app.launchArguments = ["-mock", "-noNotify", "-mockFullScreenTUI"]
        app.launch()
        defer { app.terminate() }

        let workspace = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "api-server")).firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        workspace.tap()
        let screen = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", "terminalScreen")).firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 10))
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertGreaterThan(Self.textPixels(in: screen.screenshot().image), 0, "terminal blank before zoom")

        screen.pinch(withScale: 3, velocity: 1)
        Thread.sleep(forTimeInterval: 1.5)
        let shot = screen.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThan(Self.textPixels(in: shot.image), 50, "zoomed terminal shows no text")
    }

    /// Pixels drawn by terminal text (light gray on the dark background); the blue cursor and the orange
    /// attention border do not count.
    private static func textPixels(in image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Skip a margin so the attention border is never sampled.
        let margin = 8
        var count = 0
        for y in margin..<max(margin, height - margin) {
            for x in margin..<max(margin, width - margin) {
                let i = (y * width + x) * 4
                if data[i] > 150, data[i + 1] > 150, data[i + 2] > 150 { count += 1 }
            }
        }
        return count
    }
}
