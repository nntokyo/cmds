import XCTest
@testable import CmdsCore

/// Editing a server's file (docs/guide/files.md "Editing files on a server"): the conflict check, the upload timing,
/// and download → edit → save against the in-process SFTP server.
final class RemoteEditRuleTests: XCTestCase {
    func testVersionChange() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let base = RemoteFileVersion(size: 5, modified: date)
        XCTAssertEqual(base.change(to: FileItem(name: "a", kind: .file, size: 5, modified: date)), .unchanged)
        XCTAssertEqual(base.change(to: FileItem(name: "a", kind: .file, size: 6, modified: date)), .changed)
        XCTAssertEqual(base.change(to: FileItem(name: "a", kind: .file, size: 5, modified: date + 1)), .changed)
        XCTAssertEqual(base.change(to: nil), .missing)
        XCTAssertEqual(base.change(to: FileItem(name: "a", kind: .folder, modified: date)), .notAFile)
        XCTAssertEqual(base.change(to: FileItem(name: "a", kind: .symlink, modified: date)), .notAFile)
    }

    func testUploadAfterQuietPeriod() {
        var uploads = RemoteEditUploads()
        XCTAssertEqual(uploads.handle(.changed), [.startTimer])
        // Editors write in several steps: each restarts the timer.
        XCTAssertEqual(uploads.handle(.changed), [.startTimer])
        XCTAssertTrue(uploads.isBusy)
        XCTAssertEqual(uploads.handle(.timerFired), [.upload])
        XCTAssertEqual(uploads.phase, .uploading(dirty: false))
        XCTAssertEqual(uploads.handle(.uploadFinished), [])
        XCTAssertEqual(uploads.phase, .idle)
        XCTAssertFalse(uploads.isBusy)
    }

    func testChangeDuringUploadUploadsAgainAfterIt() {
        var uploads = RemoteEditUploads()
        _ = uploads.handle(.changed)
        _ = uploads.handle(.timerFired)
        XCTAssertEqual(uploads.handle(.changed), [])
        XCTAssertEqual(uploads.handle(.changed), [])
        XCTAssertEqual(uploads.phase, .uploading(dirty: true))
        // One upload at a time; the next one after the debounce.
        XCTAssertEqual(uploads.handle(.uploadFinished), [.startTimer])
        XCTAssertEqual(uploads.handle(.timerFired), [.upload])
        XCTAssertEqual(uploads.handle(.uploadFinished), [])
        XCTAssertEqual(uploads.phase, .idle)
    }

    func testStrayEventsAreIgnored() {
        var uploads = RemoteEditUploads()
        XCTAssertEqual(uploads.handle(.timerFired), [])
        XCTAssertEqual(uploads.handle(.uploadFinished), [])
        XCTAssertEqual(uploads.phase, .idle)
    }

    func testEndWhenIdleFinishesAtOnce() {
        var uploads = RemoteEditUploads()
        XCTAssertEqual(uploads.handle(.end), [.finish])
        XCTAssertEqual(uploads.phase, .ended)
        XCTAssertEqual(uploads.handle(.changed), [])
        XCTAssertEqual(uploads.handle(.end), [])
    }

    func testEndWhileWaitingUploadsFirst() {
        var uploads = RemoteEditUploads()
        _ = uploads.handle(.changed)
        XCTAssertEqual(uploads.handle(.end), [.cancelTimer, .upload])
        XCTAssertTrue(uploads.ending)
        XCTAssertEqual(uploads.handle(.timerFired), [])
        XCTAssertEqual(uploads.handle(.uploadFinished), [.finish])
        XCTAssertEqual(uploads.phase, .ended)
    }

    func testEndDuringUploadWithNewChangesUploadsThemWithoutWaiting() {
        var uploads = RemoteEditUploads()
        _ = uploads.handle(.changed)
        _ = uploads.handle(.timerFired)
        _ = uploads.handle(.changed)
        XCTAssertEqual(uploads.handle(.end), [])
        XCTAssertEqual(uploads.handle(.uploadFinished), [.upload])
        XCTAssertEqual(uploads.handle(.uploadFinished), [.finish])
        XCTAssertEqual(uploads.phase, .ended)
    }

    func testContentHash() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-hash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(ContentHash.ofFile(file.path),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertNil(ContentHash.ofFile(file.path + "-missing"))
    }

    func testSaveTextStaysEnglish() {
        XCTAssertEqual(TransferFailure.notAFile(name: "a.txt").description,
                       "“a.txt” on the server is not a file any more; nothing was uploaded.")
        XCTAssertEqual(TransferJob.Counts([.saved, .keptTheirs]), {
            var counts = TransferJob.Counts([])
            counts.copied = 1
            counts.skipped = 1
            return counts
        }())
    }
}

final class RemoteEditSaveTests: XCTestCase {
    var root: URL!
    var home: String!
    var server: SFTPTestServer!
    var remote: SFTPFileTree!
    var local: LocalFileTree!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-edit-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        home = root.appendingPathComponent("home").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: edits, withIntermediateDirectories: true)
        local = LocalFileTree()
        local.trashItem = { _ in XCTFail("nothing on this Mac goes to the Trash") }
    }

    override func tearDownWithError() throws {
        server?.client.disconnect()
        server?.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func connect(posixRename: Bool = true) throws {
        server = SFTPTestServer(home: home)
        server.offersPosixRename = posixRename
        remote = try server.connect()
    }

    private var edits: String { root.appendingPathComponent("edits").path }
    private var copy: String { edits + "/notes.txt" }

    private func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    private func read(_ path: String) -> String? {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).map { String(decoding: $0, as: UTF8.self) }
    }

    private func names(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
    }

    /// Downloads home/notes.txt into the edit copy.
    private func download() throws -> RemoteFileCopy.Downloaded {
        try RemoteFileCopy.download(home + "/notes.txt", from: remote, to: copy)
    }

    private func saveJob(_ downloaded: RemoteFileCopy.Downloaded, name: String = "notes.txt") -> TransferJob {
        let job = TransferJob(id: 1, saving: .local(copy), to: .remote(host: "test", path: home),
                              .init(name: name, base: downloaded.version))
        job.tree = { [remote, local] location in location.isRemote ? remote! as FileTree : local! as FileTree }
        return job
    }

    /// Changes the server's file the way another user would (another size, so SFTP's whole-second times do not matter).
    private func changeOnServer(_ text: String) throws {
        try write(home + "/notes.txt", text)
    }

    func testDownloadMakesAPrivateCopyAndFollowsLinks() throws {
        try connect()
        try write(home + "/real.txt", "hello")
        chmod(home + "/real.txt", 0o644)
        try FileManager.default.createSymbolicLink(atPath: home + "/notes.txt", withDestinationPath: "real.txt")
        let downloaded = try download()
        XCTAssertEqual(read(copy), "hello")
        XCTAssertEqual(downloaded.path, home + "/real.txt")
        XCTAssertEqual(downloaded.version.size, 5)
        XCTAssertEqual(downloaded.contentHash, ContentHash.ofFile(copy))
        XCTAssertEqual(try local.item(at: copy)?.permissions, 0o600)
        XCTAssertEqual(names(edits), ["notes.txt"])
    }

    func testDownloadRefusesAFolder() throws {
        try connect()
        try FileManager.default.createDirectory(atPath: home + "/notes.txt", withIntermediateDirectories: true)
        XCTAssertThrowsError(try download()) { error in
            XCTAssertEqual(error as? TransferFailure, .notAFile(name: "notes.txt"))
        }
        XCTAssertEqual(names(edits), [])
    }

    func testSaveUploadsOverTheFileKeepingItsPermissions() throws {
        try connect()
        try write(home + "/notes.txt", "old")
        chmod(home + "/notes.txt", 0o640)
        let downloaded = try download()
        try write(copy, "edited text")
        let job = saveJob(downloaded)
        job.onConflict = { _, _, _ in XCTFail("nothing changed on the server") }
        job.run()
        let snapshot = job.snapshot
        XCTAssertEqual(snapshot.state, .done, "\(snapshot.log)")
        XCTAssertEqual(snapshot.log.map(\.outcome), [.saved])
        XCTAssertEqual(read(home + "/notes.txt"), "edited text")
        XCTAssertEqual(try local.item(at: home + "/notes.txt")?.permissions, 0o640)
        // Written to a part file, renamed over the file in one step; nothing removed, nothing left over.
        XCTAssertEqual(names(home), ["notes.txt"])
        XCTAssertEqual(server.removed, [])
        XCTAssertEqual(server.renamed.count, 1)
        XCTAssertTrue(TransferNames.isPart(RemotePath.name(server.renamed[0].0)))
        XCTAssertEqual(snapshot.saved?.name, "notes.txt")
        XCTAssertEqual(snapshot.saved?.contentHash, ContentHash.ofFile(copy))
        XCTAssertEqual(snapshot.saved?.keptTheirs, false)
        XCTAssertEqual(snapshot.saved?.version, try remote.item(at: home + "/notes.txt").map(RemoteFileVersion.init))
        XCTAssertEqual(snapshot.progress.bytesDone, 11)

        // The next save starts from the uploaded version: no conflict.
        try write(copy, "edited again")
        let next = TransferJob(id: 2, saving: .local(copy), to: .remote(host: "test", path: home),
                               .init(name: "notes.txt", base: snapshot.saved!.version))
        next.tree = job.tree
        next.onConflict = { _, _, _ in XCTFail("our own upload is not a change on the server") }
        next.run()
        XCTAssertEqual(next.snapshot.log.map(\.outcome), [.saved])
        XCTAssertEqual(read(home + "/notes.txt"), "edited again")
    }

    func testChangedOnServerAsksAndKeepMineUploads() throws {
        try connect()
        try write(home + "/notes.txt", "old")
        let downloaded = try download()
        try changeOnServer("theirs, longer")
        try write(copy, "mine")
        let job = saveJob(downloaded)
        var asked: [String] = []
        job.onConflict = { name, isFolder, reply in
            asked.append(name)
            XCTAssertFalse(isFolder)
            reply(.replace, false)
        }
        job.run()
        XCTAssertEqual(asked, ["notes.txt"])
        XCTAssertEqual(job.snapshot.log.map(\.outcome), [.saved])
        XCTAssertEqual(read(home + "/notes.txt"), "mine")
    }

    func testKeepTheirsDownloadsTheServersFileIntoTheCopy() throws {
        try connect()
        try write(home + "/notes.txt", "old")
        let downloaded = try download()
        try changeOnServer("theirs, longer")
        try write(copy, "mine")
        let job = saveJob(downloaded)
        job.onConflict = { _, _, reply in reply(.skip, false) }
        job.run()
        let snapshot = job.snapshot
        XCTAssertEqual(snapshot.state, .done)
        XCTAssertEqual(snapshot.log.map(\.outcome), [.keptTheirs])
        XCTAssertEqual(read(home + "/notes.txt"), "theirs, longer")
        XCTAssertEqual(read(copy), "theirs, longer")
        XCTAssertEqual(snapshot.saved?.keptTheirs, true)
        XCTAssertEqual(snapshot.saved?.contentHash, ContentHash.ofFile(copy))
        XCTAssertEqual(snapshot.saved?.version, try remote.item(at: home + "/notes.txt").map(RemoteFileVersion.init))
        XCTAssertEqual(names(edits), ["notes.txt"])
        XCTAssertEqual(try local.item(at: copy)?.permissions, 0o600)
    }

    func testSaveMineAsACopy() throws {
        try connect()
        try write(home + "/notes.txt", "old")
        let downloaded = try download()
        try changeOnServer("theirs, longer")
        try write(copy, "mine")
        let job = saveJob(downloaded)
        job.onConflict = { _, _, reply in reply(.keepBoth, false) }
        job.run()
        XCTAssertEqual(job.snapshot.log.map(\.outcome), [.keptBoth("notes 2.txt")])
        XCTAssertEqual(read(home + "/notes.txt"), "theirs, longer")
        XCTAssertEqual(read(home + "/notes 2.txt"), "mine")
        XCTAssertEqual(job.snapshot.saved?.name, "notes 2.txt")
    }

    func testStopOrNobodyToAskUploadsNothing() throws {
        try connect()
        try write(home + "/notes.txt", "old")
        let downloaded = try download()
        try changeOnServer("theirs, longer")
        try write(copy, "mine")
        let stopped = saveJob(downloaded)
        stopped.onConflict = { _, _, reply in reply(.stop, false) }
        stopped.run()
        XCTAssertEqual(stopped.snapshot.state, .cancelled)
        let unasked = saveJob(downloaded)
        unasked.run()
        XCTAssertEqual(unasked.snapshot.state, .cancelled)
        XCTAssertNil(unasked.snapshot.saved)
        XCTAssertEqual(read(home + "/notes.txt"), "theirs, longer")
        XCTAssertEqual(read(copy), "mine")
        XCTAssertEqual(names(home), ["notes.txt"])
    }

    func testDeletedOnServer() throws {
        try connect()
        try write(home + "/notes.txt", "old")
        let downloaded = try download()
        try FileManager.default.removeItem(atPath: home + "/notes.txt")
        try write(copy, "mine")
        // Keep theirs: nothing to take; the copy stays.
        let skipped = saveJob(downloaded)
        skipped.onConflict = { _, _, reply in reply(.skip, false) }
        skipped.run()
        XCTAssertEqual(skipped.snapshot.log.map(\.outcome), [.skipped])
        XCTAssertEqual(read(copy), "mine")
        // Keep mine: written again.
        let kept = saveJob(downloaded)
        kept.onConflict = { _, _, reply in reply(.replace, false) }
        kept.run()
        XCTAssertEqual(kept.snapshot.log.map(\.outcome), [.saved])
        XCTAssertEqual(read(home + "/notes.txt"), "mine")
    }

    func testFolderInItsPlaceFails() throws {
        try connect()
        try write(home + "/notes.txt", "old")
        let downloaded = try download()
        try FileManager.default.removeItem(atPath: home + "/notes.txt")
        try FileManager.default.createDirectory(atPath: home + "/notes.txt", withIntermediateDirectories: true)
        let job = saveJob(downloaded)
        job.onConflict = { _, _, _ in XCTFail("not asked") }
        job.run()
        XCTAssertEqual(job.snapshot.state, .failed)
        XCTAssertEqual(job.snapshot.log.map(\.outcome), [.failed(.notAFile(name: "notes.txt"))])
    }

    func testServerWithoutPosixRenameReplacesThroughItsTrash() throws {
        try connect(posixRename: false)
        try write(home + "/notes.txt", "old")
        let downloaded = try download()
        try write(copy, "mine")
        let job = saveJob(downloaded)
        job.run()
        XCTAssertEqual(job.snapshot.log.map(\.outcome), [.replaced])
        XCTAssertEqual(read(home + "/notes.txt"), "mine")
        // Never deleted: the old version is in the server's Trash.
        XCTAssertEqual(read(home + "/.local/share/Trash/files/notes.txt"), "old")
        XCTAssertEqual(server.removed, [])
    }

    func testFailedUploadLeavesTheServersFileAndNoPart() throws {
        try connect()
        try write(home + "/notes.txt", "old")
        let downloaded = try download()
        try write(copy, String(repeating: "x", count: 100_000))
        server.failWritesAfter = 40_000
        let job = saveJob(downloaded)
        job.run()
        XCTAssertEqual(job.snapshot.state, .failed)
        XCTAssertNil(job.snapshot.saved)
        XCTAssertEqual(read(home + "/notes.txt"), "old")
        XCTAssertEqual(names(home), ["notes.txt"])
        XCTAssertEqual(job.snapshot.progress.bytesDone, 0)
    }
}
