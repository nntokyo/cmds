import XCTest

/// Pictures of a page only the Mac can load (`-mock` demo data: `p-dev` shows `localhost:5173`; #174 G25).
/// Run: `-only-testing:CmdsDeviceDriver/PageSnapshotTests` on a simulator.
final class PageSnapshotTests: XCTestCase {
    func testSizesGivePicturesOfTheirShape() throws {
        #if !targetEnvironment(simulator)
        // Never relaunch the app on a real phone: it may be connected to a Mac in use.
        throw XCTSkip("simulator only")
        #endif
        let app = XCUIApplication(bundleIdentifier: "tokyo.n-n.cmds.companion")
        app.launchArguments = ["-mock", "-noNotify", "-mockWorkspace", "w-api", "-mockPane", "p-dev"]
        app.launch()
        defer { app.terminate() }

        let picture = app.descendants(matching: .any).matching(identifier: "pageSnapshot").firstMatch
        XCTAssertTrue(picture.waitForExistence(timeout: 10), "the picture as the Mac shows the pane")
        XCTAssertTrue(Self.isWide(picture.label) == true, "the demo pane as shown is wide: \(picture.label)")

        app.buttons["iPhone"].tap()
        let phone = NSPredicate { _, _ in Self.isWide(picture.label) == false }
        expectation(for: phone, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// "Picture of the page, 2,700 × 2,100 pixels": wider than tall? nil without two numbers.
    private static func isWide(_ label: String) -> Bool? {
        let numbers = label.replacingOccurrences(of: ",", with: "").split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count >= 2 else { return nil }
        return numbers[numbers.count - 2] > numbers[numbers.count - 1]
    }
}
