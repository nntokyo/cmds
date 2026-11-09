import XCTest
@testable import CmdsCore

/// Worktree workspaces (#172): path rules, git output parsing, and creating, comparing and removing worktrees in
/// temporary repositories with a local bare "remote" (no network).
final class WorktreeTests: XCTestCase {
    private var root: String!
    private var remote: String!
    private var repo: String!

    override func setUpWithError() throws {
        try XCTSkipIf(Git.executable == nil, "git is not installed")
        root = WorktreePaths.canonical(NSTemporaryDirectory() + "cmds-worktree-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        remote = root + "/remote.git"
        repo = root + "/app"
        try git(["init", "--quiet", "--bare", "-b", "master", remote], in: root)
        try git(["config", "core.hooksPath", "/dev/null"], in: remote)
        try git(["init", "--quiet", "-b", "master", repo], in: root)
        try isolate(repo)
        try write("README.md", "hello\n", in: repo)
        try commit("first", in: repo)
        try git(["remote", "add", "origin", remote], in: repo)
        try git(["push", "--quiet", "-u", "origin", "master"], in: repo)
        try git(["remote", "set-head", "origin", "master"], in: repo)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(atPath: root) }
    }

    // MARK: - Helpers

    @discardableResult
    private func git(_ arguments: [String], in directory: String) throws -> String {
        try Git.check(arguments, in: directory)
    }

    /// No global hooks, signing or identity of the user's git configuration in the test repositories.
    private func isolate(_ repository: String) throws {
        try git(["config", "core.hooksPath", "/dev/null"], in: repository)
        try git(["config", "commit.gpgsign", "false"], in: repository)
        try git(["config", "user.name", "cmds test"], in: repository)
        try git(["config", "user.email", "test@example.invalid"], in: repository)
    }

    private func write(_ name: String, _ text: String, in directory: String) throws {
        try text.write(toFile: (directory as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func commit(_ message: String, in directory: String) throws {
        try git(["add", "-A"], in: directory)
        try git(["commit", "--quiet", "-m", message], in: directory)
    }

    private func create(_ branch: String, base: String? = nil, path: String? = nil) throws -> WorktreeRecord {
        try Worktrees.create(Worktrees.Request(branch: branch, base: base, path: path), from: repo).record
    }

    private func XCTAssertThrowsWorktreeError(_ expected: WorktreeError, _ body: () throws -> Void,
                                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? WorktreeError, expected, file: file, line: line)
        }
    }

    // MARK: - Paths

    func testDefaultPathIsASiblingFolderOfTheRepository() {
        XCTAssertEqual(WorktreePaths.defaultPath(repository: "/src/app", branch: "fix-login"), "/src/app-worktrees/fix-login")
        XCTAssertEqual(WorktreePaths.defaultPath(repository: "/src/app/", branch: "feature/a/b"), "/src/app-worktrees/feature-a-b")
        XCTAssertEqual(WorktreePaths.defaultParent(repository: "/src/app"), "/src/app-worktrees")
    }

    func testCanonicalResolvesLinksOfTheExistingPart() {
        XCTAssertEqual(WorktreePaths.canonical("/tmp/cmds-no-such-folder/x/../y"), "/private/tmp/cmds-no-such-folder/y")
        XCTAssertTrue(WorktreePaths.isInside("/a/b/c", "/a/b"))
        XCTAssertTrue(WorktreePaths.isInside("/a/b", "/a/b"))
        XCTAssertFalse(WorktreePaths.isInside("/a/bc", "/a/b"))
    }

    func testNewPathMustBeAbsoluteNewAndOutsideTheRepository() throws {
        XCTAssertThrowsWorktreeError(.pathNotAbsolute("rel/x")) { _ = try WorktreePaths.checkNew("rel/x", repository: repo) }
        XCTAssertThrowsWorktreeError(.pathExists(root)) { _ = try WorktreePaths.checkNew(root, repository: repo) }
        let inside = repo + "/sub/wt"
        XCTAssertThrowsWorktreeError(.pathInsideRepository(inside)) { _ = try WorktreePaths.checkNew(inside, repository: repo) }
        // Through a link to the repository.
        let link = root + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: repo)
        XCTAssertThrowsWorktreeError(.pathInsideRepository(link + "/wt")) {
            _ = try WorktreePaths.checkNew(link + "/wt", repository: repo)
        }
        XCTAssertEqual(try WorktreePaths.checkNew(root + "/elsewhere/wt", repository: repo), root + "/elsewhere/wt")
    }

    func testWorkingTreeRootFindsTheNearestGitEntry() throws {
        try FileManager.default.createDirectory(atPath: repo + "/a/b", withIntermediateDirectories: true)
        XCTAssertEqual(WorktreePaths.workingTreeRoot(of: repo + "/a/b"), repo)
        XCTAssertNil(WorktreePaths.workingTreeRoot(of: root))
    }

    // MARK: - Parsing

    func testParseWorktreeList() {
        let text = "worktree /src/app\nHEAD 1234\nbranch refs/heads/master\n\nworktree /src/app-worktrees/x\nHEAD 5678\n"
            + "branch refs/heads/x\nlocked busy\n\nworktree /src/y\nHEAD 9\ndetached\nlocked\n"
        XCTAssertEqual(WorktreeOutput.parseList(text), [
            .init(path: "/src/app", locked: false), .init(path: "/src/app-worktrees/x", locked: true),
            .init(path: "/src/y", locked: true),
        ])
    }

    func testCountStatusSeparatesUntrackedAndCountsRenamesOnce() {
        var output = Data(" M a.txt\0R  new.txt\0old.txt\0?? n.txt\0!! ignored\0".utf8)
        output.append(contentsOf: [UInt8(ascii: "?"), UInt8(ascii: "?"), 0x20, 0xFF, 0xFE, 0])  // not UTF-8
        let counts = WorktreeOutput.countStatus(output)
        XCTAssertEqual(counts.changed, 2)
        XCTAssertEqual(counts.untracked, 2)
    }

    // MARK: - Create

    func testCreateMakesABranchWithoutUpstreamInASiblingFolder() throws {
        let record = try create("feature/one")
        XCTAssertEqual(record.path, root + "/app-worktrees/feature-one")
        XCTAssertEqual(record.repository, repo)
        XCTAssertEqual(record.branch, "feature/one")
        XCTAssertEqual(record.base, "origin/master")
        XCTAssertEqual(try git(["symbolic-ref", "--short", "HEAD"], in: record.path), "feature/one")
        // No upstream: a plain `git push` never goes to the base.
        XCTAssertFalse(try Git.run(["rev-parse", "--abbrev-ref", "feature/one@{upstream}"], in: repo).succeeded)
        // The main working tree is untouched.
        XCTAssertEqual(try git(["status", "--porcelain"], in: repo), "")
    }

    func testCreateStartsFromTheFetchedRemoteBranch() throws {
        // Someone else pushes to master; the new branch starts from it although the local master is behind.
        let other = root + "/other"
        try git(["-c", "core.hooksPath=/dev/null", "clone", "--quiet", remote, other], in: root)
        try isolate(other)
        try write("b.txt", "b\n", in: other)
        try commit("second", in: other)
        try git(["push", "--quiet", "origin", "master"], in: other)
        let record = try create("two")
        XCTAssertEqual(try git(["log", "-1", "--format=%s"], in: record.path), "second")
    }

    func testCreateWithBaseAndPath() throws {
        try git(["branch", "develop"], in: repo)
        let path = root + "/custom/place"
        let record = try create("three", base: "develop", path: path)
        XCTAssertEqual(record.path, path)
        XCTAssertEqual(record.base, "develop")
        XCTAssertThrowsWorktreeError(.unknownBase("nope")) { _ = try create("four", base: "nope") }
    }

    func testCreateRefusesExistingBranchesPathsAndBadNames() throws {
        try git(["branch", "taken"], in: repo)
        XCTAssertThrowsWorktreeError(.branchExists("taken")) { _ = try create("taken") }
        // A branch only on the remote is taken too.
        try git(["push", "--quiet", "origin", "master:remote-only"], in: repo)
        try git(["fetch", "--quiet", "origin"], in: repo)
        XCTAssertThrowsWorktreeError(.branchExists("remote-only")) { _ = try create("remote-only") }
        for bad in ["", "-x", "a..b", "HEAD", "@{-1}", "with space"] {
            XCTAssertThrowsWorktreeError(.invalidBranch(bad)) { _ = try create(bad) }
        }
        let existing = root + "/exists"
        try FileManager.default.createDirectory(atPath: existing, withIntermediateDirectories: true)
        XCTAssertThrowsWorktreeError(.pathExists(existing)) { _ = try create("five", path: existing) }
        XCTAssertThrowsWorktreeError(.pathInsideRepository(repo + "/wt")) { _ = try create("six", path: repo + "/wt") }
        XCTAssertThrowsWorktreeError(.notARepository(root)) {
            _ = try Worktrees.create(Worktrees.Request(branch: "seven"), from: root)
        }
        // Nothing was created by the refused requests.
        XCTAssertEqual(try git(["worktree", "list", "--porcelain"], in: repo).components(separatedBy: "worktree ").count, 2)
        for name in ["five", "six", "seven"] {
            XCTAssertFalse(try Git.run(["show-ref", "--verify", "--quiet", "refs/heads/" + name], in: repo).succeeded)
        }
    }

    func testCreateFromInsideALinkedWorktreeUsesTheMainRepository() throws {
        let first = try create("eight")
        let second = try Worktrees.create(Worktrees.Request(branch: "nine"), from: first.path).record
        XCTAssertEqual(second.repository, repo)
        XCTAssertEqual(second.path, root + "/app-worktrees/nine")
    }

    func testFetchFailureIsAWarning() throws {
        try git(["remote", "set-url", "origin", root + "/missing.git"], in: repo)
        let creation = try Worktrees.create(Worktrees.Request(branch: "offline"), from: repo)
        XCTAssertNotNil(creation.fetchWarning)
        XCTAssertEqual(creation.record.base, "origin/master")
    }

    // MARK: - Changes

    func testChangesListCommitsAndTheWorkingTree() throws {
        let record = try create("changes")
        try write("committed.txt", "c\n", in: record.path)
        try commit("add committed", in: record.path)
        try write("README.md", "hello\nchanged\n", in: record.path)
        try write("untracked.txt", "u\n", in: record.path)
        let changes = try Worktrees.changes(in: record.path, base: record.base)
        XCTAssertEqual(changes.base, "origin/master")
        XCTAssertEqual(changes.branch, "changes")
        XCTAssertTrue(changes.text.contains("add committed"), changes.text)
        XCTAssertTrue(changes.text.contains("+++ b/committed.txt"), changes.text)
        XCTAssertTrue(changes.text.contains("+changed"), changes.text)
        XCTAssertTrue(changes.text.contains("+++ b/untracked.txt"), changes.text)
        // The `#` lines on top: what is compared, then the commits.
        let lines = changes.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("# Changes in \(record.path) (changes) since origin/master (merge base "), lines[0])
        XCTAssertTrue(lines[0].hasSuffix("), working tree included"), lines[0])
        XCTAssertEqual(lines[1], "# Commits (newest first):")
        XCTAssertTrue(lines[2].hasPrefix("#   ") && lines[2].hasSuffix(" add committed"), lines[2])
        XCTAssertEqual(lines[3], "")
        XCTAssertTrue(lines[4].hasPrefix("diff --git "), lines[4])
        // Without a base: the repository's default branch.
        XCTAssertEqual(try Worktrees.changes(in: record.path, base: nil).base, "origin/master")
        let unchanged = try Worktrees.changes(in: repo, base: nil).text
        XCTAssertTrue(unchanged.contains("\n# No commits since origin/master.\n\n# No changes in the working tree"), unchanged)
    }

    // MARK: - Remove

    func testRemovalIsRefusedWhileWorkCouldBeLost() throws {
        let record = try create("work")
        XCTAssertEqual(try Worktrees.removalRefusals(record), [])

        try write("README.md", "edited\n", in: record.path)
        XCTAssertEqual(try Worktrees.removalRefusals(record), [.uncommittedChanges(1)])
        XCTAssertThrowsWorktreeError(.refused([.uncommittedChanges(1)])) { try Worktrees.remove(record) }

        try git(["checkout", "--quiet", "--", "README.md"], in: record.path)
        try write("new.txt", "n\n", in: record.path)
        XCTAssertEqual(try Worktrees.removalRefusals(record), [.untrackedFiles(1)])

        try commit("local only", in: record.path)
        XCTAssertEqual(try Worktrees.removalRefusals(record), [.unpushedCommits(1)])
        XCTAssertThrowsWorktreeError(.refused([.unpushedCommits(1)])) { try Worktrees.remove(record) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path + "/new.txt"))

        try git(["worktree", "lock", record.path], in: repo)
        XCTAssertEqual(try Worktrees.removalRefusals(record), [.locked, .unpushedCommits(1)])
        try git(["worktree", "unlock", record.path], in: repo)

        try git(["push", "--quiet", "origin", "work"], in: record.path)
        XCTAssertEqual(try Worktrees.removalRefusals(record), [])
        try Worktrees.remove(record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
        // The empty <repo>-worktrees folder goes too; the branch stays.
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/app-worktrees"))
        XCTAssertTrue(try Git.run(["show-ref", "--verify", "--quiet", "refs/heads/work"], in: repo).succeeded)
    }

    func testCommitsOnTheBaseAreNotUnpushed() throws {
        try git(["branch", "develop"], in: repo)
        let record = try create("on-base", base: "develop")
        try write("x.txt", "x\n", in: record.path)
        try commit("x", in: record.path)
        try git(["branch", "--force", "develop", "on-base"], in: repo)  // as if merged locally
        XCTAssertEqual(try Worktrees.removalRefusals(record), [])
    }

    func testOnlyLinkedWorktreesOfTheRecordedRepositoryCanBeRemoved() throws {
        // The main working tree, a folder that is not a worktree and a missing folder are never removed.
        let main = WorktreeRecord(path: repo, repository: repo, branch: "master", base: "origin/master")
        XCTAssertEqual(try Worktrees.removalRefusals(main), [.notAWorktree])
        XCTAssertThrowsWorktreeError(.refused([.notAWorktree])) { try Worktrees.remove(main) }
        let plain = root + "/plain"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let notWorktree = WorktreeRecord(path: plain, repository: repo, branch: "x", base: "origin/master")
        XCTAssertEqual(try Worktrees.removalRefusals(notWorktree), [.notAWorktree])
        XCTAssertTrue(FileManager.default.fileExists(atPath: plain))
        let gone = WorktreeRecord(path: root + "/gone", repository: repo, branch: "x", base: "origin/master")
        XCTAssertEqual(try Worktrees.removalRefusals(gone), [.notAWorktree])
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/README.md"))
    }

    // MARK: - Store

    func testStoreRoundTripAndDamagedFile() throws {
        let url = URL(fileURLWithPath: root + "/support/worktrees.json")
        let record = WorktreeRecord(path: "/a-worktrees/b", repository: "/a", branch: "b", base: "origin/main",
                                    created: Date(timeIntervalSince1970: 1_700_000_000))
        try WorktreeStore.save([record], to: url)
        XCTAssertEqual(WorktreeStore.load(from: url).records, [record])
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        try Data("{".utf8).write(to: url)
        let loaded = WorktreeStore.load(from: url)
        XCTAssertEqual(loaded.records, [])
        XCTAssertNotNil(loaded.movedAside)
        XCTAssertEqual(WorktreeStore.load(from: URL(fileURLWithPath: root + "/none.json")).records, [])
    }
}
