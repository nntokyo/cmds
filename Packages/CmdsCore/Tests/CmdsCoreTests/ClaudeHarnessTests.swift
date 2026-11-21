import XCTest
@testable import CmdsCore

final class ClaudeHarnessTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("harness-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("projects/-Users-me-src-app", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("memory"), withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"Always run the tests before committing"}}"#,
            #"{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"ok"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Use pnpm, token=abc123secretvalue"}]}}"#,
            "not json",
        ]
        try lines.joined(separator: "\n").write(to: project.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        try "Prefers pnpm.".write(to: project.appendingPathComponent("memory/prefs.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("skills/existing"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testScanCountsWithoutWriting() {
        let overview = ClaudeHarness.scan(claudeFolder: root, days: 7, home: root.path)
        XCTAssertEqual(overview.projects.map(\.folder), ["-Users-me-src-app"])
        XCTAssertEqual(overview.projects.first?.sessions, 1)
        XCTAssertEqual(overview.projects.first?.prompts, 2, "not tool results, slash commands or bad lines")
        XCTAssertEqual(overview.projects.first?.memoryFiles, ["prefs.md"])
        XCTAssertEqual(overview.models, ["claude-opus-5-5": 1])
        XCTAssertEqual(overview.skills, ["existing"])
        XCTAssertTrue(ClaudeHarness.overviewMarkdown(overview, days: 7).contains("| Sessions | 1 |"))
        XCTAssertEqual(ClaudeHarness.scan(claudeFolder: root, days: 7, now: Date().addingTimeInterval(30 * 86_400), home: root.path)
            .projects.first?.sessions, 0, "older sessions are not counted (memory still lists the project)")
    }

    func testDigestMasksSecretsAndPrefixes() {
        let digest = ClaudeHarness.digest(projectFolder: root.appendingPathComponent("projects/-Users-me-src-app"),
                                          since: Date().addingTimeInterval(-86_400), prefix: "[app] ")
        XCTAssertTrue(digest.contains("- [app] Always run the tests before committing"), digest)
        XCTAssertTrue(digest.contains("token=[REDACTED]"), digest)
        XCTAssertFalse(digest.contains("abc123secretvalue"))
        XCTAssertEqual(ClaudeHarness.digest(projectFolder: root.appendingPathComponent("projects/-Users-me-src-app"),
                                            since: Date().addingTimeInterval(-86_400), until: Date().addingTimeInterval(-3_600)), "",
                       "until excludes later sessions")
        XCTAssertTrue(ClaudeHarness.memory(projectFolder: root.appendingPathComponent("projects/-Users-me-src-app")).contains("Prefers pnpm."))
        XCTAssertEqual(ClaudeHarness.memory(projectFolder: root.appendingPathComponent("projects/-Users-me-src-app"), files: ["../x.md"]), "")
    }

    func testRedaction() {
        let text = """
            key sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAA and ghp_abcdefghijklmnopqrstuvwxyz123456
            Authorization: Bearer abcdefghijklmnopqrstuvwx
            password: "hunter2 is here"
            -----BEGIN OPENSSH PRIVATE KEY-----
            b3BlbnNzaC1rZXktdjEAAAAA
            -----END OPENSSH PRIVATE KEY-----
            AKIAABCDEFGHIJKLMNOP plain words stay
            """
        let masked = ClaudeHarness.redact(text)
        for secret in ["sk-ant-api03", "ghp_abc", "abcdefghijklmnopqrstuvwx", "hunter2", "b3BlbnNzaC1rZXktdjEAAAAA", "AKIAABCDEFGHIJKLMNOP"] {
            XCTAssertFalse(masked.contains(secret), "\(secret) in \(masked)")
        }
        XCTAssertTrue(masked.contains("plain words stay"))
        XCTAssertEqual(ClaudeHarness.redact("nothing secret here"), "nothing secret here")
    }

    func testProjectNamesAndSkillNames() {
        XCTAssertEqual(ClaudeHarness.projectFolderName("/Users/r/Source/tools/cmds"), "-Users-r-Source-tools-cmds")
        XCTAssertEqual(ClaudeHarness.projectFolderName("/Users/r/a.b"), "-Users-r-a-b")
        XCTAssertEqual(ClaudeHarness.skillName("---\nname: deploy-checks\ndescription: x\n---\nbody"), "deploy-checks")
        XCTAssertNil(ClaudeHarness.skillName("---\nname: ../evil\n---"))
        XCTAssertNil(ClaudeHarness.skillName("---\nname: Has Spaces\n---"))
        XCTAssertNil(ClaudeHarness.skillName("no front matter"))
    }

    func testApplyBacksUpFirst() throws {
        let file = root.appendingPathComponent("proj/CLAUDE.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let backup = try XCTUnwrap(ClaudeHarness.applyFile("new", to: file, backups: root.appendingPathComponent("backups")))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "old")
        XCTAssertNil(try ClaudeHarness.applyFile("fresh", to: root.appendingPathComponent("new/CLAUDE.md"),
                                                 backups: root.appendingPathComponent("backups")), "nothing to back up")
    }

    func testClaudeRunsWithoutToolsOrSettings() {
        let arguments = ClaudeHarness.claudeArguments(model: "sonnet")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--tools")! + 1], "")
        XCTAssertTrue(arguments.contains("--no-session-persistence"))
        XCTAssertTrue(arguments.contains("--strict-mcp-config"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--setting-sources")! + 1], "")
    }
}
