import XCTest
import CmdsCore
@testable import cmds_cli

/// Commands that read a pane take it only as `--pane P`. A bare pane id used to be ignored, so `cmds read p2` printed
/// the focused pane's screen instead of p2's (#61); it is now a usage error, given before anything is sent to the app.
final class PaneArgumentCLITests: XCTestCase {
    /// A socket that does not exist: a command line that passes the checks fails with `unavailable` when it connects.
    private let environment = ["CMDS_SOCKET_PATH": "/nonexistent/cmds-cli-tests/cmds.sock"]

    private func exitCode(_ words: [String]) -> Int32 {
        CLI.main(words, environment: environment)
    }

    func testReadRejectsABarePaneID() {
        XCTAssertEqual(exitCode(["read", "p2"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["read", "--pane", "p1", "p2"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["read", "--scrollback", "50", "p2"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["read", "--pane", "p2"]), CLIError.Code.unavailable.rawValue)
        XCTAssertEqual(exitCode(["read"]), CLIError.Code.unavailable.rawValue)
    }

    func testBrowserReadsRejectABarePaneID() {
        XCTAssertEqual(exitCode(["browser", "url", "p2"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["browser", "snapshot", "p2"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["browser", "url", "--pane", "p2"]), CLIError.Code.unavailable.rawValue)
    }

    /// `cmds browser snapshot` (#169): bad values, and several devices without -o, are usage errors.
    func testBrowserSnapshotOptions() throws {
        XCTAssertEqual(exitCode(["browser", "snapshot", "--device", "nokia"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["browser", "snapshot", "--device", "iphone,ipad"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["browser", "snapshot", "--selector", ""]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["browser", "snapshot", "--full", "-o", "/tmp/x.png", "--pane", "p2"]),
                       CLIError.Code.unavailable.rawValue)

        let args = try Arguments(["--full", "--selector", "main", "--device", "iphone,800x600"],
                                 options: ["pane", "output", "selector", "device"], flags: ["full"])
        let request = try CLI.browserSnapshotRequest(args)
        XCTAssertEqual(request.params["fullPage"] ?? nil, .bool(true))
        XCTAssertEqual(request.params["selector"] ?? nil, .string("main"))
        XCTAssertEqual(request.params["devices"] ?? nil, .array(["iphone", "800x600"]))
        XCTAssertTrue(try CLI.browserSnapshotRequest(try Arguments([])).isPlain)

        let images = ["iphone", "800x600"].map { BrowserSnapshotImage(device: $0, width: 1, height: 1, png: Data()) }
        XCTAssertEqual(CLI.snapshotPaths("/tmp/shot.png", images: images), ["/tmp/shot-iphone.png", "/tmp/shot-800x600.png"])
        XCTAssertEqual(CLI.snapshotPaths("/tmp/shot", images: images), ["/tmp/shot-iphone.png", "/tmp/shot-800x600.png"])
        XCTAssertEqual(CLI.snapshotPaths("/tmp/one.png", images: [images[0]]), ["/tmp/one.png"])
    }

    /// `cmds browser responsive` (#170): bad device lists and conflicting options are usage errors.
    func testBrowserResponsive() throws {
        XCTAssertEqual(exitCode(["browser", "responsive", "--devices", "iphone"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["browser", "responsive", "--devices", "a,b"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["browser", "responsive", "--sync-scroll", "--no-sync-scroll"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["browser", "responsive", "--off", "--devices", "iphone,ipad"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["browser", "responsive", "--pane", "p2", "http://x.test"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["browser", "responsive", "--off", "http://x.test"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["browser", "responsive", "--pane", "p2"]), CLIError.Code.unavailable.rawValue)

        let flags: Set<String> = ["no-sync-scroll", "sync-scroll", "off", "no-focus"]
        let on = try CLI.browserResponsiveChange(try Arguments(["--devices", "iphone,desktop-1920", "--no-sync-scroll"],
                                                               options: ["pane", "devices"], flags: flags))
        XCTAssertEqual(on, BrowserResponsiveChange(on: true, devices: ["iphone", "desktop-1920"], syncScroll: false))
        let off = try CLI.browserResponsiveChange(try Arguments(["--off"], options: ["pane", "devices"], flags: flags))
        XCTAssertEqual(off, BrowserResponsiveChange(on: false))
    }

    /// `cmds browser device` (#168): bad sizes and schemes are usage errors before anything is sent.
    func testBrowserDevice() throws {
        XCTAssertEqual(exitCode(["browser", "device", "nokia"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["browser", "device", "20x20"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["browser", "device", "--scheme", "sepia"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["browser", "device", "iphone", "ipad"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["browser", "device", "--pane", "p2", "iphone-se"]), CLIError.Code.unavailable.rawValue)
        XCTAssertEqual(exitCode(["browser", "device", "--list"]), 0)

        let args = try Arguments(["--rotate", "--ua", "", "--scheme", "dark", "390x844"], options: ["pane", "ua", "scheme"],
                                 flags: ["rotate", "list"])
        let change = try CLI.browserViewportChange(args)
        XCTAssertEqual(change.params["width"] ?? nil, .number(390))
        XCTAssertEqual(change.params["height"] ?? nil, .number(844))
        XCTAssertEqual(change.params["rotate"] ?? nil, .bool(true))
        XCTAssertEqual(change.params["userAgent"] ?? nil, .string(""))
        XCTAssertEqual(change.params["colorScheme"] ?? nil, .string("dark"))
        XCTAssertEqual(try CLI.browserViewportChange(try Arguments(["off"])).params["device"] ?? nil, .string("off"))
        XCTAssertTrue(CLI.presetTable().contains("iphone-se"))
    }
}
