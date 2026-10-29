import XCTest

/// Drives the already-installed, already-running companion app from the command line (device or simulator),
/// without reinstalling or relaunching it. Steps come from `CMDS_UI_SCRIPT` (pass it to xcodebuild as
/// `TEST_RUNNER_CMDS_UI_SCRIPT=...`), separated by `;;`:
///
///     tap:<label or identifier>     tap the first element with that label/identifier
///     tapContains:<text>            tap the first element whose label contains <text>
///     tapText:<text>                tap the first static text containing <text>
///     type:<text>                   type into the focused element (\n = return)
///     wait:<seconds>
///     back                          navigation bar back button
///     dump                          print the accessibility tree
///
/// Example:
///     xcodebuild test-without-building -xctestrun ... -destination id=<udid> \
///       TEST_RUNNER_CMDS_UI_SCRIPT='tapText:e2e;;tap:left;;type:c;;dump'
final class DeviceDriverTests: XCTestCase {
    func testRunScript() throws {
        let script = ProcessInfo.processInfo.environment["CMDS_UI_SCRIPT"] ?? "dump"
        let app = XCUIApplication(bundleIdentifier: "tokyo.n-n.cmds.companion")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        for step in script.components(separatedBy: ";;") where !step.isEmpty {
            let (command, argument) = Self.split(step)
            print("CMDS_UI_STEP \(command) \(argument)")
            switch command {
            case "tap":
                let element = app.descendants(matching: .any).matching(
                    NSPredicate(format: "label == %@ OR identifier == %@", argument, argument)).firstMatch
                XCTAssertTrue(element.waitForExistence(timeout: 5), "no element \(argument)")
                element.tap()
            case "tapContains":
                let element = app.descendants(matching: .any).matching(
                    NSPredicate(format: "label CONTAINS %@", argument)).firstMatch
                XCTAssertTrue(element.waitForExistence(timeout: 5), "no element containing \(argument)")
                element.tap()
            case "tapText":
                let element = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", argument)).firstMatch
                XCTAssertTrue(element.waitForExistence(timeout: 5), "no text \(argument)")
                element.tap()
            case "type":
                app.typeText(argument.replacingOccurrences(of: "\\n", with: "\n"))
            case "wait":
                Thread.sleep(forTimeInterval: Double(argument) ?? 1)
            case "back":
                app.navigationBars.buttons.element(boundBy: 0).tap()
            case "dump":
                print("CMDS_UI_DUMP_BEGIN\n\(app.debugDescription)\nCMDS_UI_DUMP_END")
            default:
                XCTFail("unknown step \(step)")
            }
        }
    }

    private static func split(_ step: String) -> (String, String) {
        guard let colon = step.firstIndex(of: ":") else { return (step, "") }
        return (String(step[..<colon]), String(step[step.index(after: colon)...]))
    }
}
