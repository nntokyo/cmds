import Foundation
import XCTest
@testable import CmdsCore

/// A `cmds` found first on PATH runs the CLI of the app that opened the terminal (CMDS_CLI_PATH).
final class CLIHandoffTests: XCTestCase {
    private let app = "/Applications/cmds Beta.app/Contents/Resources/bin/cmds"
    private let installed = "/usr/local/bin/cmds"
    /// /usr/local/bin/cmds links to /Applications/cmds.app's CLI.
    private func resolve(_ path: String) -> String {
        path == installed ? "/Applications/cmds.app/Contents/Resources/bin/cmds" : path
    }

    private func target(_ environment: [String: String], own: String?, executable: Bool = true) -> String? {
        CLIHandoff.target(environment: environment, ownPath: own, isExecutable: { _ in executable }, resolve: resolve)
    }

    func testAnotherAppsCLIHandsOff() {
        XCTAssertEqual(target([CmdsEnv.cliPath: app], own: installed), app)
    }

    func testTheSameCLIGoesOn() {
        XCTAssertNil(target([CmdsEnv.cliPath: app], own: app))
        // The installed link resolves to the app's own CLI.
        XCTAssertNil(target([CmdsEnv.cliPath: "/Applications/cmds.app/Contents/Resources/bin/cmds"], own: installed))
    }

    func testNoHandoffWithoutAUsableTarget() {
        XCTAssertNil(target([:], own: installed), "outside cmds terminals")
        XCTAssertNil(target([CmdsEnv.cliPath: "cmds"], own: installed), "relative paths are ignored")
        XCTAssertNil(target([CmdsEnv.cliPath: app], own: installed, executable: false), "the app was moved or deleted")
        XCTAssertNil(target([CmdsEnv.cliPath: app], own: nil))
    }

    func testAHandoffNeverRepeats() {
        XCTAssertNil(target([CmdsEnv.cliPath: app, CmdsEnv.cliHandoff: "1"], own: installed))
    }

    func testResolvedPathFollowsLinks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-handoff-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("real")
        try Data().write(to: file)
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertEqual(CLIHandoff.resolvedPath(link.path), CLIHandoff.resolvedPath(file.path))
        XCTAssertEqual(CLIHandoff.resolvedPath("/no/such/file"), "/no/such/file")
    }
}
