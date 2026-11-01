import XCTest
@testable import cmds_cli

/// `cmds --version` reports the version the CLI was built with (#16).
final class CLIVersionTests: XCTestCase {
    func testVersionFromTheEmbeddedInfoPlist() {
        XCTAssertEqual(CLI.bundleVersion(["CFBundleShortVersionString": "0.2.1", "CFBundleVersion": "6"]), "0.2.1")
    }

    func testDevWithoutAVersion() {
        XCTAssertEqual(CLI.bundleVersion(nil), "dev")
        XCTAssertEqual(CLI.bundleVersion([:]), "dev")
        XCTAssertEqual(CLI.bundleVersion(["CFBundleShortVersionString": ""]), "dev")
    }
}
