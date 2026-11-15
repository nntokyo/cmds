@testable import CmdsCore
import XCTest

final class ClaudeChromeHostTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-chrome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeManifest(home: String, browser: String = "Google/Chrome", host: String) throws -> String {
        let dir = "\(home)/Library/Application Support/\(browser)/NativeMessagingHosts"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/\(ClaudeChromeHost.manifestName)"
        let json = #"{"name":"com.anthropic.claude_code_browser_extension","path":"\#(host)","type":"stdio"}"#
        try Data(json.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func writeScript(_ path: String, _ text: String, mode: Int = 0o755) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data(text.utf8), attributes: [.posixPermissions: mode])
    }

    func testNoManifestIsFine() throws {
        let home = try temporaryDirectory().path
        XCTAssertEqual(ClaudeChromeHost.check(home: home), [])
    }

    func testMissingScriptIsRepairedFromAnotherAccount() throws {
        let home = try temporaryDirectory().path
        let missing = "\(home)/.claude-app/chrome/chrome-native-host"
        let manifest = try writeManifest(home: home, host: missing)
        let working = "#!/bin/sh\nexec /x/claude --chrome-native-host\n"
        try writeScript("\(home)/.claude-work/chrome/chrome-native-host", working)

        XCTAssertEqual(ClaudeChromeHost.check(home: home),
                       [ClaudeChromeHost.Broken(manifest: manifest, host: missing, repairable: true)])
        let written = try ClaudeChromeHost.repair(ClaudeChromeHost.check(home: home),
                                                  configDirs: ["\(home)/.claude-app", "\(home)/.claude-work"], home: home)
        XCTAssertEqual(written, [missing])
        XCTAssertEqual(try String(contentsOfFile: missing, encoding: .utf8), working)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: missing))
        XCTAssertEqual(ClaudeChromeHost.check(home: home), [])
        // The manifest is not touched.
        XCTAssertTrue(try String(contentsOfFile: manifest, encoding: .utf8).contains(missing))
    }

    func testRepairWritesWrapperForFoundClaude() throws {
        let home = try temporaryDirectory().path
        let missing = "\(home)/.claude-app/chrome/chrome-native-host"
        _ = try writeManifest(home: home, host: missing)
        try writeScript("\(home)/.local/bin/claude", "#!/bin/sh\n")
        try ClaudeChromeHost.repair(ClaudeChromeHost.check(home: home), configDirs: [], home: home)
        XCTAssertEqual(try String(contentsOfFile: missing, encoding: .utf8),
                       ClaudeChromeHost.wrapper(claude: "\(home)/.local/bin/claude"))
    }

    func testRepairWithoutClaudeThrows() throws {
        let home = try temporaryDirectory().path
        _ = try writeManifest(home: home, host: "\(home)/.claude-app/chrome/chrome-native-host")
        XCTAssertThrowsError(try ClaudeChromeHost.repair(ClaudeChromeHost.check(home: home), configDirs: [], home: home))
    }

    func testForeignHostIsNotRepairable() throws {
        let home = try temporaryDirectory().path
        _ = try writeManifest(home: home, host: "/nowhere/host")
        XCTAssertEqual(ClaudeChromeHost.check(home: home).map(\.repairable), [false])
        XCTAssertEqual(try ClaudeChromeHost.repair(ClaudeChromeHost.check(home: home), configDirs: [], home: home), [])
    }

    func testNotExecutableScriptGetsItsModeOnly() throws {
        let home = try temporaryDirectory().path
        let host = "\(home)/.claude-app/chrome/chrome-native-host"
        _ = try writeManifest(home: home, browser: "BraveSoftware/Brave-Browser", host: host)
        try writeScript(host, "#!/bin/sh\nmine\n", mode: 0o644)
        try writeScript("\(home)/.local/bin/claude", "#!/bin/sh\n")
        XCTAssertEqual(try ClaudeChromeHost.repair(ClaudeChromeHost.check(home: home), configDirs: [], home: home), [host])
        XCTAssertEqual(try String(contentsOfFile: host, encoding: .utf8), "#!/bin/sh\nmine\n")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: host))
    }

    func testWrapperQuotesPaths() {
        XCTAssertTrue(ClaudeChromeHost.wrapper(claude: "/a b/claude").contains("exec '/a b/claude' --chrome-native-host"))
    }
}
