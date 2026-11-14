import CmdsCore
import XCTest

/// #290: setting up agy's status line for its quota.
final class AntigravitySettingsTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testState() {
        XCTAssertEqual(AntigravitySettings.state(of: nil), .noFile)
        XCTAssertEqual(AntigravitySettings.state(of: data(" \n")), .notSetUp)
        XCTAssertEqual(AntigravitySettings.state(of: data(#"{"theme":"dark"}"#)), .notSetUp)
        XCTAssertEqual(AntigravitySettings.state(of: data(#"{"statusLine":{"type":"command","command":"cmds hook agy-status"}}"#)), .setUp)
        XCTAssertEqual(AntigravitySettings.state(of: data(#"{"statusLine":{"command":"'/Applications/cmds.app/Contents/Resources/bin/cmds' hook agy-status"}}"#)), .setUp)
        XCTAssertEqual(AntigravitySettings.state(of: data(#"{"statusLine":{"command":"~/bin/line.sh"}}"#)), .otherCommand("~/bin/line.sh"))
        XCTAssertEqual(AntigravitySettings.state(of: data("[1]")), .unreadable)
        XCTAssertEqual(AntigravitySettings.state(of: data("{")), .unreadable)
    }

    func testSettingUpKeepsOtherKeys() throws {
        let cli = "/Applications/cmds.app/Contents/Resources/bin/cmds"
        let out = try XCTUnwrap(AntigravitySettings.settingUp(data(#"{"theme":"dark","statusLine":{"command":"x"}}"#), cli: cli))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: out) as? [String: Any])
        XCTAssertEqual(object["theme"] as? String, "dark")
        let line = try XCTUnwrap(object["statusLine"] as? [String: Any])
        XCTAssertEqual(line["command"] as? String, "\(cli) hook agy-status")
        XCTAssertEqual(line["type"] as? String, "command")
        XCTAssertEqual(line["stack_with_default"] as? Bool, true)
        XCTAssertEqual(AntigravitySettings.state(of: out), .setUp)
    }

    func testSettingUpANewFileAndQuoting() throws {
        let out = try XCTUnwrap(AntigravitySettings.settingUp(nil, cli: "/Users/a b/cmds"))
        XCTAssertEqual(AntigravitySettings.state(of: out), .setUp)
        let line = try XCTUnwrap((try JSONSerialization.jsonObject(with: out) as? [String: Any])?["statusLine"] as? [String: Any])
        XCTAssertEqual(line["command"] as? String, "'/Users/a b/cmds' hook agy-status")
        XCTAssertNil(AntigravitySettings.settingUp(data("[1]"), cli: "cmds"))
    }

    func testTheLimitsStoreKeepsAntigravityApart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let limits = AgentLimits(agent: .antigravity, limits: [UsageLimit(id: "gemini-5h", usedPercent: 40, resetsAt: now + 3600, windowMinutes: 300)],
                                 plan: nil, updatedAt: now)
        try CodexLimitsStore.save(limits, supportDirectory: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("antigravity-limits.json").path))
        XCTAssertEqual(CodexLimitsStore.load(supportDirectory: directory, agent: .antigravity, now: now), limits)
        XCTAssertNil(CodexLimitsStore.load(supportDirectory: directory, now: now))
        XCTAssertNil(CodexLimitsStore.load(supportDirectory: directory, agent: .antigravity, now: now + 7200))
    }

    func testShortLabelsForTheFooter() {
        let gemini = UsageLimit(id: "gemini-5h", usedPercent: 1, windowMinutes: 300)
        let thirdParty = UsageLimit(id: "3p-weekly", usedPercent: 1, windowMinutes: 7 * 1440)
        XCTAssertEqual(AgentFormat.limitLabel(gemini), "Gemini 5h")
        XCTAssertEqual(AgentFormat.limitLabel(gemini, short: true), "5h")
        XCTAssertEqual(AgentFormat.limitLabel(thirdParty, short: true), "3P 7d")
        XCTAssertEqual(AgentKind.antigravity.shortName, "agy")
        XCTAssertEqual(AgentKind.claude.shortName, "Claude")
    }
}
