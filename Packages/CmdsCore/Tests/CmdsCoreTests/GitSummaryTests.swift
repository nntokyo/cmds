import Foundation
import XCTest
@testable import CmdsCore

/// The sidebar's git summary from `git status --porcelain=v2 --branch -z` (#174 G16).
final class GitSummaryTests: XCTestCase {
    private func data(_ fields: [String]) -> Data { Data((fields.joined(separator: "\0") + "\0").utf8) }

    func testChangesAndAheadBehind() {
        let output = data([
            "# branch.oid 0123456789abcdef", "# branch.head main", "# branch.upstream origin/main", "# branch.ab +2 -1",
            "1 .M N... 100644 100644 100644 aaa bbb Sources/a.swift",
            "2 R. N... 100644 100644 100644 aaa bbb R100 Sources/new.swift", "Sources/old.swift",
            "u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.txt",
            "? notes.md",
            "! build/out",
        ])
        let summary = GitSummary.parse(output)
        XCTAssertEqual(summary, GitSummary(changes: 4, ahead: 2, behind: 1, upstream: "origin/main"))
        XCTAssertEqual(summary?.badge, "±4 ↑2 ↓1")
    }

    func testCleanWithoutUpstream() {
        let summary = GitSummary.parse(data(["# branch.oid abc", "# branch.head topic"]))
        XCTAssertEqual(summary, GitSummary(changes: 0))
        XCTAssertEqual(summary?.badge, "")
        XCTAssertEqual(GitSummary(changes: 0, ahead: 0, behind: 3).badge, "↓3")
    }

    func testNotPorcelainV2() {
        XCTAssertNil(GitSummary.parse(Data()))
        XCTAssertNil(GitSummary.parse(data([" M file.txt"])))
    }

    func testAgainstARealRepository() throws {
        guard let git = Git.executable else { throw XCTSkip("no git") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-gitsummary-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func run(_ arguments: [String]) -> Data? {
            CommandOutput.run(git, ["-C", folder.path] + arguments,
                              environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                                            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                                            "GIT_COMMITTER_EMAIL": "t@t", "PATH": "/usr/bin:/bin"], timeout: 10)
        }
        _ = run(["init", "-q", "-b", "main"])
        try "a".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = run(["add", "a.txt"])
        _ = run(["commit", "-q", "-m", "one"])
        try "b".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new".write(to: folder.appendingPathComponent("new file.txt"), atomically: true, encoding: .utf8)
        let output = try XCTUnwrap(run(GitSummary.statusArguments))
        XCTAssertEqual(GitSummary.parse(output), GitSummary(changes: 2))
    }
}
