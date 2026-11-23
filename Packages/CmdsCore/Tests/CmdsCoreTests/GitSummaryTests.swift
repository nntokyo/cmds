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

    func testPaths() {
        let output = data([
            "# branch.oid abc", "# branch.head main",
            "1 .M N... 100644 100644 100644 aaa bbb Sources/with space.swift",
            "2 R. N... 100644 100644 100644 aaa bbb R100 Sources/new.swift", "Sources/old.swift",
            "u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.txt",
            "? notes.md",
            "! build/out",
        ])
        XCTAssertEqual(GitSummary.parseWithPaths(output)?.paths,
                       ["Sources/with space.swift", "Sources/new.swift", "Sources/old.swift", "conflict.txt", "notes.md"])
    }

    func testOverlapsAcrossWorktrees() {
        typealias C = GitOverlap.Checkout
        let found = GitOverlap.find([
            C(workspace: "w1", project: "/r", worktree: "/r", paths: ["a.swift", "b.swift", "c.swift"]),
            C(workspace: "w2", project: "/r", worktree: "/r-wt/x", paths: ["b.swift", "c.swift", "z.swift"]),
            C(workspace: "w3", project: "/r", worktree: "/r", paths: ["a.swift"]),  // the same checkout as w1
            C(workspace: "w4", project: "/other", worktree: "/other", paths: ["b.swift"]),  // another repository
            C(workspace: "w5", project: "/r", worktree: "/r-wt/y", paths: []),
        ])
        XCTAssertEqual(found["w1"], [GitOverlap(workspaces: ["w2"], files: ["b.swift", "c.swift"], count: 2)])
        // w1 and w3 share a worktree: one entry naming both, with what either changed.
        XCTAssertEqual(found["w2"], [GitOverlap(workspaces: ["w1", "w3"], files: ["b.swift", "c.swift"], count: 2)])
        XCTAssertNil(found["w3"], "w3 shares w1's checkout and changes nothing w2 changes")
        XCTAssertNil(found["w4"])
        XCTAssertNil(found["w5"])
        let many = Set((0..<30).map { "f\($0)" })
        let cut = GitOverlap.find([C(workspace: "a", project: "/p", worktree: "/p", paths: many),
                                   C(workspace: "b", project: "/p", worktree: "/q", paths: many)])
        XCTAssertEqual(cut["a"]?.first?.files.count, GitOverlap.maxFiles)
        XCTAssertEqual(cut["a"]?.first?.count, 30)
    }

    func testPathsFromASubfolderOfARealWorktree() throws {
        guard let git = Git.executable else { throw XCTSkip("no git") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-overlap-\(UUID().uuidString.prefix(8))")
        let main = root.appendingPathComponent("main"), linked = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: main.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "t",
                           "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t", "PATH": "/usr/bin:/bin"]
        func run(_ folder: URL, _ arguments: [String]) -> Data? {
            CommandOutput.run(git, ["-C", folder.path] + arguments, environment: environment, timeout: 10)
        }
        _ = run(main, ["init", "-q", "-b", "main"])
        try "1".write(to: main.appendingPathComponent("src/app.swift"), atomically: true, encoding: .utf8)
        _ = run(main, ["add", "."])
        _ = run(main, ["commit", "-q", "-m", "one"])
        _ = run(main, ["worktree", "add", "-q", "-b", "topic", linked.path])
        try "2".write(to: main.appendingPathComponent("src/app.swift"), atomically: true, encoding: .utf8)
        try "3".write(to: linked.appendingPathComponent("src/app.swift"), atomically: true, encoding: .utf8)
        let fromSubfolder = try XCTUnwrap(run(main.appendingPathComponent("src"), GitSummary.statusArguments))
        let fromLinked = try XCTUnwrap(run(linked, GitSummary.statusArguments))
        XCTAssertEqual(GitSummary.parseWithPaths(fromSubfolder)?.paths, ["src/app.swift"], "relative to the top level")
        XCTAssertEqual(GitSummary.parseWithPaths(fromLinked)?.paths, ["src/app.swift"])
    }
}
