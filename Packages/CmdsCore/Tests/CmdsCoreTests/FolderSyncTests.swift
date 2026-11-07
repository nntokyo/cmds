import XCTest
@testable import CmdsCore

/// `FolderSync`: planning (pure), comparing two trees, and running a plan as a `.sync` transfer job, between this Mac
/// and the in-process SFTP server (no network).
final class FolderSyncPlanTests: XCTestCase {
    private let old = Date(timeIntervalSince1970: 1_700_000_000)
    private let new = Date(timeIntervalSince1970: 1_700_000_100)

    private func file(_ name: String, _ size: Int64 = 1, _ date: Date? = nil) -> FileItem {
        FileItem(name: name, kind: .file, size: size, modified: date ?? old)
    }

    private func entry(_ path: String, _ left: FileItem?, _ right: FileItem?, _ status: FolderSync.Status) -> FolderSync.Entry {
        FolderSync.Entry(leftPath: path, rightPath: path, left: left, right: right, status: status)
    }

    private var sample: [FolderSync.Entry] {
        [
            entry("a", file("a"), nil, .leftOnly),
            entry("b", nil, file("b"), .rightOnly),
            entry("c", file("c", 1, new), file("c", 2, old), .modified),
            entry("d", file("d", 1, old), file("d", 2, new), .modified),
            entry("e", file("e", 1, old), file("e", 2, old), .modified),
            entry("f", file("f"), file("f"), .same),
            entry("g", FileItem(name: "g", kind: .symlink), nil, .skipped),
            entry("h", FileItem(name: "h", kind: .folder), FileItem(name: "h", kind: .folder), .unreadable),
            entry("i", FileItem(name: "i", kind: .folder), file("i", 1, new), .modified),
        ]
    }

    private func kinds(_ decisions: [FolderSync.Decision]) -> [String: FolderSync.Action.Kind?] {
        Dictionary(uniqueKeysWithValues: decisions.map { ($0.entry.path, $0.action?.kind) })
    }

    func testOneWayCopiesNewAndModifiedAndTrashesExtrasOnlyWhenAsked() {
        let plan = FolderSync.plan(sample, options: .init(direction: .leftToRight))
        let actions = kinds(plan)
        XCTAssertNil(actions["f"], "same items are left out")
        XCTAssertEqual(actions["a"], .copy(to: .right))
        XCTAssertEqual(actions["b"], .some(nil), "extra items stay without Delete extra items")
        XCTAssertEqual(actions["c"], .copy(to: .right))
        XCTAssertEqual(actions["d"], .copy(to: .right))
        XCTAssertEqual(actions["i"], .copy(to: .right))
        XCTAssertEqual(actions["g"], .some(nil))
        XCTAssertEqual(actions["h"], .some(nil))
        XCTAssertFalse(plan.contains(where: \.isConflict))
        XCTAssertEqual(plan.filter(\.replacesNewer).map(\.entry.path), ["d"])

        let deleting = kinds(FolderSync.plan(sample, options: .init(direction: .leftToRight, deleteExtra: true)))
        XCTAssertEqual(deleting["b"], .trash(.right))
        XCTAssertEqual(deleting["a"], .copy(to: .right))

        let back = kinds(FolderSync.plan(sample, options: .init(direction: .rightToLeft, deleteExtra: true)))
        XCTAssertEqual(back["a"], .trash(.left))
        XCTAssertEqual(back["b"], .copy(to: .left))
        XCTAssertEqual(back["c"], .copy(to: .left))
    }

    func testTwoWayCopiesMissingItemsBothWaysAndNeverTrashes() {
        let plan = FolderSync.plan(sample, options: .init(direction: .both, deleteExtra: true))
        let actions = kinds(plan)
        XCTAssertEqual(actions["a"], .copy(to: .right))
        XCTAssertEqual(actions["b"], .copy(to: .left))
        XCTAssertFalse(plan.contains { if case .trash? = $0.action?.kind { return true } else { return false } })
        XCTAssertEqual(Set(plan.filter(\.isConflict).map(\.entry.path)), ["c", "d", "e", "i"])
    }

    func testTwoWayConflictRulesAndChoices() {
        let newer = kinds(FolderSync.plan(sample, options: .init(direction: .both)))
        XCTAssertEqual(newer["c"], .copy(to: .right), "left is newer")
        XCTAssertEqual(newer["d"], .copy(to: .left), "right is newer")
        XCTAssertEqual(newer["e"], .some(nil), "same date, different size: unsettled")
        XCTAssertEqual(newer["i"], .some(nil), "a folder against a file: unsettled")

        let left = kinds(FolderSync.plan(sample, options: .init(direction: .both, conflictRule: .left)))
        XCTAssertEqual(left["d"], .copy(to: .right))
        XCTAssertEqual(left["i"], .copy(to: .right))
        let right = kinds(FolderSync.plan(sample, options: .init(direction: .both, conflictRule: .right)))
        XCTAssertEqual(right["c"], .copy(to: .left))
        let skip = kinds(FolderSync.plan(sample, options: .init(direction: .both, conflictRule: .skip)))
        XCTAssertEqual(skip["c"], .some(nil))

        let chosen = kinds(FolderSync.plan(sample, options: .init(direction: .both),
                                           choices: ["c": .useRight, "e": .useLeft, "d": .skip]))
        XCTAssertEqual(chosen["c"], .copy(to: .left))
        XCTAssertEqual(chosen["e"], .copy(to: .right))
        XCTAssertEqual(chosen["d"], .some(nil))
        // A choice also overrides a one-way direction for that item.
        let oneWay = kinds(FolderSync.plan(sample, options: .init(direction: .leftToRight), choices: ["d": .skip]))
        XCTAssertEqual(oneWay["d"], .some(nil))
    }

    func testSameAndMatches() {
        XCTAssertTrue(FolderSync.isSame(file("x", 3, old), file("x", 3, old.addingTimeInterval(0.9))))
        XCTAssertFalse(FolderSync.isSame(file("x", 3, old), file("x", 3, old.addingTimeInterval(5))))
        XCTAssertFalse(FolderSync.isSame(file("x", 3, old), file("x", 4, old)))
        XCTAssertTrue(FolderSync.isSame(FileItem(name: "x", kind: .file, size: 3), file("x", 3)), "no date: size only")
        XCTAssertTrue(FolderSync.matches(nil, nil))
        XCTAssertFalse(FolderSync.matches(file("x"), nil))
        XCTAssertFalse(FolderSync.matches(nil, file("x")))
        XCTAssertTrue(FolderSync.matches(FileItem(name: "x", kind: .folder, modified: new),
                                         FileItem(name: "x", kind: .folder, modified: old)))
        XCTAssertFalse(FolderSync.matches(file("x", 1, new), file("x", 1, old)))
    }

    func testSummary() {
        let actions = FolderSync.plan(sample, options: .init(direction: .both)).compactMap(\.action)
        let summary = FolderSync.Summary(actions, unsettled: 2)
        XCTAssertEqual(summary.toRight, 2) // a, c
        XCTAssertEqual(summary.toLeft, 2) // b, d
        XCTAssertEqual(summary.unsettled, 2)
        XCTAssertFalse(summary.isEmpty)
        XCTAssertTrue(FolderSync.Summary([]).isEmpty)
    }
}

final class FolderSyncTreeTests: XCTestCase {
    var root: URL!
    var home: String!
    var server: SFTPTestServer!
    var remote: SFTPFileTree!
    var local: LocalFileTree!
    var localTrash: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-foldersync-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        home = root.appendingPathComponent("home").path
        try FileManager.default.createDirectory(atPath: home + "/site", withIntermediateDirectories: true)
        localTrash = root.appendingPathComponent("local-trash")
        try FileManager.default.createDirectory(at: localTrash, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: mac, withIntermediateDirectories: true)
        server = SFTPTestServer(home: home)
        remote = try server.connect()
        local = LocalFileTree()
        let trash = localTrash!
        local.trashItem = { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        }
    }

    override func tearDownWithError() throws {
        server.client.disconnect()
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private var mac: String { root.appendingPathComponent("mac").path }
    private var site: String { home + "/site" }
    private let old = Date(timeIntervalSince1970: 1_700_000_000)
    private let new = Date(timeIntervalSince1970: 1_700_000_100)

    private func write(_ path: String, _ text: String, date: Date? = nil) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: date ?? old], ofItemAtPath: path)
    }

    private func read(_ path: String) -> String? {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).map { String(decoding: $0, as: UTF8.self) }
    }

    private func compare(hidden: Bool = false, maxItems: Int = FolderSync.defaultMaxItems) throws -> FolderSync.Comparison {
        try FolderSync.compare(left: local, mac, right: remote, site,
                               options: .init(includeHidden: hidden, maxItems: maxItems))
    }

    private func statuses(_ comparison: FolderSync.Comparison) -> [String: FolderSync.Status] {
        Dictionary(uniqueKeysWithValues: comparison.entries.map { ($0.path, $0.status) })
    }

    private func syncJob(_ comparison: FolderSync.Comparison, _ options: FolderSync.Options,
                         choices: [String: FolderSync.Choice] = [:]) -> TransferJob {
        let actions = FolderSync.plan(comparison.entries, options: options, choices: choices).compactMap(\.action)
        let job = TransferJob(id: 1, syncing: .init(left: .local(mac), right: .remote(host: "test", path: site),
                                                     direction: options.direction, actions: actions))
        job.tree = { [remote, local] location in location.isRemote ? remote! as FileTree : local! as FileTree }
        return job
    }

    /// A small project on this Mac and an older copy of it on the server.
    private func makeTrees() throws {
        try write(mac + "/index.html", "<h1>new</h1>", date: new)
        try write(site + "/index.html", "<h1>old</h1>")
        try write(mac + "/same.txt", "same")
        try write(site + "/same.txt", "same")
        try write(mac + "/css/a.css", "a{}")
        try write(site + "/css/a.css", "a{}")
        try write(mac + "/css/b.css", "b{}")
        try write(mac + "/img/logo.png", "png")
        try write(site + "/old.html", "gone")
        try write(site + "/css/extra.css", "x")
        try write(mac + "/.env", "secret")
        try FileManager.default.createSymbolicLink(atPath: mac + "/latest", withDestinationPath: "index.html")
    }

    func testCompareLocalWithRemote() throws {
        try makeTrees()
        let comparison = try compare()
        XCTAssertFalse(comparison.truncated)
        XCTAssertEqual(statuses(comparison), [
            "css": .same, "css/a.css": .same, "css/b.css": .leftOnly, "css/extra.css": .rightOnly,
            "img": .leftOnly, "index.html": .modified, "latest": .skipped, "old.html": .rightOnly, "same.txt": .same,
        ])
        // An item before its contents; the folder only on the left is one item.
        XCTAssertEqual(comparison.entries.map(\.path).first, "css")
        XCTAssertEqual(comparison.entries.first { $0.path == "index.html" }?.newer, .left)
        XCTAssertEqual(statuses(try compare(hidden: true))[".env"], .leftOnly)
    }

    func testPartFilesAreLeftOutAndTruncationStops() throws {
        try makeTrees()
        try write(site + "/" + TransferNames.part(for: "x.txt"), "partial")
        XCTAssertFalse(try compare().entries.contains { TransferNames.isPart($0.path) })
        let truncated = try compare(maxItems: 3)
        XCTAssertTrue(truncated.truncated)
    }

    func testCompareCanBeCancelledAndNeedsReadableRoots() throws {
        try makeTrees()
        XCTAssertThrowsError(try FolderSync.compare(left: local, mac, right: remote, site, isCancelled: { true })) {
            XCTAssertTrue($0 is FolderSync.Cancelled)
        }
        XCTAssertThrowsError(try FolderSync.compare(left: local, mac + "/missing", right: remote, site))
    }

    func testUnreadableFolderIsNotSynced() throws {
        try write(mac + "/private/a.txt", "a")
        try write(site + "/private/b.txt", "b")
        chmod(mac + "/private", 0)
        defer { chmod(mac + "/private", 0o755) }
        let comparison = try compare()
        XCTAssertEqual(statuses(comparison), ["private": .unreadable])
        XCTAssertNotNil(comparison.entries[0].error)
        let plan = FolderSync.plan(comparison.entries, options: .init(direction: .leftToRight, deleteExtra: true))
        XCTAssertNil(plan[0].action)
    }

    func testOneWayUploadReplacesThroughTheTrashAndDeletesExtrasOnlyToTheTrash() throws {
        try makeTrees()
        let job = syncJob(try compare(), .init(direction: .leftToRight, deleteExtra: true))
        job.run()
        let snapshot = job.snapshot
        XCTAssertEqual(snapshot.state, .done, "\(snapshot.log)")
        XCTAssertEqual(read(site + "/index.html"), "<h1>new</h1>")
        XCTAssertEqual(read(site + "/css/b.css"), "b{}")
        XCTAssertEqual(read(site + "/img/logo.png"), "png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: site + "/old.html"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: site + "/css/extra.css"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: site + "/.env"), "hidden items stay out")
        XCTAssertFalse(FileManager.default.fileExists(atPath: site + "/latest"), "links are not synced")
        // Replaced and extra items are in the server's Trash; nothing was removed but part files.
        let trash = home + "/.local/share/Trash/files"
        XCTAssertEqual(read(trash + "/index.html"), "<h1>old</h1>")
        XCTAssertEqual(read(trash + "/old.html"), "gone")
        XCTAssertEqual(read(trash + "/extra.css"), "x")
        XCTAssertEqual(server.removed, [])
        let outcomes = Dictionary(uniqueKeysWithValues: snapshot.log.filter { !$0.path.hasPrefix("img/") }
            .map { ($0.path, $0.outcome) })
        XCTAssertEqual(outcomes, ["index.html": .replaced, "css/b.css": .copied, "img": .copied,
                                  "old.html": .trashed, "css/extra.css": .trashed])
        XCTAssertTrue(snapshot.log.allSatisfy { $0.side == .right })
        XCTAssertEqual(snapshot.counts.trashed, 2)
        XCTAssertEqual(TransferInfo(snapshot).trashed, 2)
        XCTAssertEqual(TransferInfo(snapshot).direction, .leftToRight)
        XCTAssertEqual(snapshot.syncDirection, .leftToRight)
        // The dates came along, so the folders now compare the same.
        let after = try compare().differences
        XCTAssertTrue(after.allSatisfy { $0.status == .skipped }, "\(after)")
    }

    func testTwoWayNewerWinsBothWays() throws {
        try write(mac + "/a.txt", "mac newer", date: new)
        try write(site + "/a.txt", "server")
        try write(mac + "/b.txt", "mac")
        try write(site + "/b.txt", "server newer", date: new)
        try write(mac + "/only-mac.txt", "m")
        try write(site + "/only-server/x.txt", "s")
        let job = syncJob(try compare(), .init(direction: .both))
        job.run()
        XCTAssertEqual(job.snapshot.state, .done, "\(job.snapshot.log)")
        XCTAssertEqual(read(site + "/a.txt"), "mac newer")
        XCTAssertEqual(read(mac + "/b.txt"), "server newer")
        XCTAssertEqual(read(site + "/only-mac.txt"), "m")
        XCTAssertEqual(read(mac + "/only-server/x.txt"), "s")
        // The Mac's old b.txt went to this Mac's Trash.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: localTrash.path).filter { $0.hasSuffix("b.txt") }.count, 1)
        XCTAssertEqual(Set(job.snapshot.log.filter { $0.side == .left }.map(\.path)), ["b.txt", "only-server", "only-server/x.txt"])
        XCTAssertEqual(try compare().differences, [])
    }

    func testItemChangedSinceTheComparisonIsLeftAlone() throws {
        try makeTrees()
        let job = syncJob(try compare(), .init(direction: .leftToRight, deleteExtra: true))
        // Someone edits the server's copy and adds the file that was missing, after the comparison.
        try write(site + "/index.html", "<h1>edited on the server</h1>", date: new)
        try write(site + "/css/b.css", "theirs")
        try write(site + "/old.html", "changed too", date: new)
        job.run()
        let snapshot = job.snapshot
        XCTAssertEqual(snapshot.state, .failed, "\(snapshot.log)")
        XCTAssertEqual(read(site + "/index.html"), "<h1>edited on the server</h1>")
        XCTAssertEqual(read(site + "/css/b.css"), "theirs")
        XCTAssertEqual(read(site + "/old.html"), "changed too")
        let changed = snapshot.log.filter { $0.outcome == .failed(.changedSinceCompare) }.map(\.path)
        XCTAssertEqual(Set(changed), ["index.html", "css/b.css", "old.html"])
        // Retry does not take them again (they need a new comparison).
        XCTAssertTrue(job.prepareRetry())
        job.run()
        XCTAssertEqual(job.snapshot.state, .done)
        XCTAssertEqual(read(site + "/index.html"), "<h1>edited on the server</h1>")
    }

    func testFolderReplacingAFileAndRetryAfterAFailure() throws {
        try write(mac + "/docs/a.txt", String(repeating: "a", count: 50_000))
        try write(mac + "/docs/b.txt", String(repeating: "b", count: 50_000))
        try write(site + "/docs", "a file where the Mac has a folder")
        server.failWritesAfter = 60_000
        let job = syncJob(try compare(), .init(direction: .leftToRight))
        job.run()
        XCTAssertEqual(job.snapshot.state, .failed)
        // The file went to the Trash before the folder was made; the part file of b.txt was removed.
        XCTAssertEqual(read(home + "/.local/share/Trash/files/docs"), "a file where the Mac has a folder")
        XCTAssertEqual(server.removed.count, 1)

        server.failWritesAfter = nil
        XCTAssertTrue(job.prepareRetry())
        job.run()
        let snapshot = job.snapshot
        XCTAssertEqual(snapshot.state, .done, "\(snapshot.log)")
        XCTAssertEqual(read(site + "/docs/b.txt"), String(repeating: "b", count: 50_000))
        XCTAssertEqual(snapshot.log.last?.outcome, .merged)
    }

    func testDownloadToThisMacReplacesThroughItsTrash() throws {
        try write(mac + "/notes.txt", "mine")
        try write(site + "/notes.txt", "server's", date: new)
        let job = syncJob(try compare(), .init(direction: .rightToLeft))
        job.run()
        XCTAssertEqual(job.snapshot.state, .done, "\(job.snapshot.log)")
        XCTAssertEqual(read(mac + "/notes.txt"), "server's")
        let trashed = try FileManager.default.contentsOfDirectory(atPath: localTrash.path)
        XCTAssertEqual(trashed.count, 1)
        XCTAssertEqual(read(localTrash.path + "/" + trashed[0]), "mine")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: mac).contains { TransferNames.isPart($0) })
    }

    func testReplaceIsRefusedWhenTheTrashFails() throws {
        try write(mac + "/notes.txt", "mine")
        try write(site + "/notes.txt", "server's", date: new)
        local.trashItem = { _ in throw FileTreeError("no Trash here") }
        let job = syncJob(try compare(), .init(direction: .rightToLeft))
        job.run()
        XCTAssertEqual(job.snapshot.state, .failed)
        XCTAssertEqual(read(mac + "/notes.txt"), "mine")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: mac).contains { TransferNames.isPart($0) })
        guard case .failed(.existingNotTrashed)? = job.snapshot.log.last?.outcome else {
            return XCTFail("\(job.snapshot.log)")
        }
    }

    func testLocalToLocal() throws {
        let other = root.appendingPathComponent("other").path
        try write(mac + "/a.txt", "a")
        try write(other + "/b.txt", "b")
        let comparison = try FolderSync.compare(left: local, mac, right: local, other)
        let actions = FolderSync.plan(comparison.entries, options: .init(direction: .both)).compactMap(\.action)
        let job = TransferJob(id: 2, syncing: .init(left: .local(mac), right: .local(other), direction: .both, actions: actions))
        job.tree = { [local] _ in local! }
        job.run()
        XCTAssertEqual(job.snapshot.state, .done, "\(job.snapshot.log)")
        XCTAssertEqual(read(other + "/a.txt"), "a")
        XCTAssertEqual(read(mac + "/b.txt"), "b")
    }
}
