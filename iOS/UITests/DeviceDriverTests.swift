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
///     pinch:<scale>                 pinch the terminal screen (>1 zooms in)
///     value:<identifier>            print `CMDS_UI_VALUE <identifier> <accessibility value>`
///     waitValue:<id>~<text>[~secs]  wait (default 30 s) until that value contains <text>, else fail;
///                                   e.g. waitValue:connectionStatus~path=bluetooth (debug builds)
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
            case "pinch":
                let element = app.descendants(matching: .any).matching(
                    NSPredicate(format: "label == %@", "Terminal screen")).firstMatch
                XCTAssertTrue(element.waitForExistence(timeout: 5), "no terminal screen")
                let scale = CGFloat(Double(argument) ?? 2)
                element.pinch(withScale: scale, velocity: scale >= 1 ? 1 : -1)
            case "value":
                let element = Self.element(app, argument)
                XCTAssertTrue(element.waitForExistence(timeout: 5), "no element \(argument)")
                print("CMDS_UI_VALUE \(argument) \(element.value as? String ?? "")")
            case "waitValue":
                // waitValue:<identifier>~<substring>[~seconds]
                let parts = argument.components(separatedBy: "~")
                guard parts.count >= 2 else { XCTFail("usage: waitValue:<identifier>~<substring>[~seconds]"); break }
                let element = Self.element(app, parts[0])
                let deadline = Date().addingTimeInterval(parts.count > 2 ? Double(parts[2]) ?? 30 : 30)
                var value = ""
                while Date() < deadline {
                    value = element.exists ? element.value as? String ?? "" : ""
                    if value.contains(parts[1]) { break }
                    Thread.sleep(forTimeInterval: 0.5)
                }
                print("CMDS_UI_VALUE \(parts[0]) \(value)")
                XCTAssertTrue(value.contains(parts[1]), "\(parts[0]) value does not contain \(parts[1]): \(value)")
            case "back":
                app.navigationBars.buttons.element(boundBy: 0).tap()
            case "dump":
                print("CMDS_UI_DUMP_BEGIN\n\(app.debugDescription)\nCMDS_UI_DUMP_END")
            default:
                XCTFail("unknown step \(step)")
            }
        }
    }

    private static func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ OR label == %@", identifier, identifier)).firstMatch
    }

    private static func split(_ step: String) -> (String, String) {
        guard let colon = step.firstIndex(of: ":") else { return (step, "") }
        return (String(step[..<colon]), String(step[step.index(after: colon)...]))
    }
}
