import XCTest
@testable import CmdsCore

final class SFTPCodecTests: XCTestCase {
    func testPacketFraming() {
        let packet = SFTP.packet(.initialize) { $0.uint32(3) }
        XCTAssertEqual([UInt8](packet), [0, 0, 0, 5, 1, 0, 0, 0, 3])
    }

    func testAttributesRoundTrip() throws {
        let attributes = SFTP.Attributes(size: 1 << 40, uid: 501, gid: 20, permissions: 0o100644, accessTime: 1,
                                         modificationTime: 1_700_000_000)
        var writer = SFTP.Writer()
        writer.attributes(attributes)
        var reader = SFTP.Reader(writer.data)
        XCTAssertEqual(try reader.attributes(), attributes)
        XCTAssertTrue(reader.isAtEnd)
        XCTAssertEqual(attributes.fileType, .file)
        XCTAssertEqual(SFTP.Attributes(permissions: 0o040755).fileType, .folder)
        XCTAssertEqual(SFTP.Attributes(permissions: 0o120777).fileType, .symlink)
        XCTAssertEqual(SFTP.Attributes().fileType, .unknown)
    }

    func testDecodeNameAndStatus() throws {
        let name = SFTP.packet(.name) { w in
            w.uint32(7)
            w.uint32(1)
            w.string("a b.txt")
            w.string("-rw-r--r-- a b.txt")
            w.attributes(SFTP.Attributes(size: 3))
        }
        let response = try SFTP.decodeResponse(name.dropFirst(4))
        XCTAssertEqual(response, .name(id: 7, [SFTP.NameEntry(name: "a b.txt", longName: "-rw-r--r-- a b.txt",
                                                               attributes: SFTP.Attributes(size: 3))]))
        let status = SFTP.packet(.status) { w in w.uint32(9); w.uint32(2); w.string("No such file"); w.string("en") }
        XCTAssertEqual(try SFTP.decodeResponse(status.dropFirst(4)), .status(id: 9, code: 2, message: "No such file"))
        XCTAssertEqual(SFTPError.status(code: 2, message: "").description, "No such file or folder")
    }

    func testTruncatedAndUnknownPacketsAreErrors() {
        let status = SFTP.packet(.status) { w in w.uint32(9) }
        XCTAssertThrowsError(try SFTP.decodeResponse(status.dropFirst(4)))
        XCTAssertThrowsError(try SFTP.decodeResponse(Data([99])))
        // A request type is not a reply.
        XCTAssertThrowsError(try SFTP.decodeResponse(Data([SFTP.PacketType.open.rawValue, 0, 0, 0, 1])))
        var writer = SFTP.Writer()
        writer.uint32(UInt32(SFTP.maxPacketLength + 1))
        var reader = SFTP.Reader(writer.data)
        XCTAssertThrowsError(try reader.bytes())
    }
}

final class FileLocationTests: XCTestCase {
    func testParse() throws {
        XCTAssertEqual(try FileLocation.parse("home:/var/www"), .remote(host: "home", path: "/var/www"))
        XCTAssertEqual(try FileLocation.parse("me@host:"), .remote(host: "me@host", path: ""))
        XCTAssertEqual(try FileLocation.parse("host:~/src"), .remote(host: "host", path: "~/src"))
        XCTAssertEqual(try FileLocation.parse("host:docs"), .remote(host: "host", path: "docs"))
        XCTAssertEqual(try FileLocation.parse("[::1]:/tmp"), .remote(host: "[::1]", path: "/tmp"))
        XCTAssertEqual(try FileLocation.parse("ssh://me@host:2222/srv"), .remote(host: "ssh://me@host:2222", path: "/srv"))
        // Local: no colon, a slash before the colon, or a leading colon.
        XCTAssertEqual(try FileLocation.parse("/tmp/a:b"), .local("/tmp/a:b"))
        XCTAssertEqual(try FileLocation.parse("./a:b"), .local("./a:b"))
        XCTAssertEqual(try FileLocation.parse("notes.txt"), .local("notes.txt"))
        XCTAssertEqual(try FileLocation.parse(":x"), .local(":x"))
        XCTAssertThrowsError(try FileLocation.parse("-oProxyCommand=x:/tmp"))
        XCTAssertThrowsError(try FileLocation.parse("host:/a\nb"))
        XCTAssertEqual(FileLocation.remote(host: "h", path: "/a").description, "h:/a")
    }

    func testRemotePaths() {
        XCTAssertEqual(RemotePath.join("/", "a"), "/a")
        XCTAssertEqual(RemotePath.join("/a", "b"), "/a/b")
        XCTAssertEqual(RemotePath.parent("/a/b"), "/a")
        XCTAssertEqual(RemotePath.parent("/a"), "/")
        XCTAssertEqual(RemotePath.name("/a/b/"), "b")
        XCTAssertEqual(RemotePath.name("/"), "/")
        XCTAssertEqual(RemotePath.normalized("/a/./b/../c//d"), "/a/c/d")
        XCTAssertEqual(RemotePath.normalized("/.."), "/")
        XCTAssertTrue(RemotePath.isSameOrInside("/a/b", "/a"))
        XCTAssertFalse(RemotePath.isSameOrInside("/ab", "/a"))
        XCTAssertEqual(RemotePath.resolve(typed: "../x", in: "/a/b"), "/a/x")
        XCTAssertEqual(RemotePath.resolve(typed: "~/x", in: "/a/b"), "~/x")
    }
}

final class SSHFileCommandTests: XCTestCase {
    func testArguments() {
        let args = SSHFileCommand.arguments(host: "home")
        XCTAssertEqual(Array(args.suffix(4)), ["-s", "--", "home", "sftp"])
        let options = stride(from: 0, to: args.count - 1, by: 1).filter { args[$0] == "-o" }.map { args[$0 + 1] }
        XCTAssertTrue(options.contains("BatchMode=yes"))
        XCTAssertTrue(options.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(options.contains("ControlMaster=no"))
        XCTAssertTrue(options.contains("ClearAllForwardings=yes"))
        XCTAssertFalse(options.contains { $0.lowercased().hasPrefix("stricthostkeychecking=no") || $0.contains("accept-new") })
        XCTAssertFalse(options.contains { $0.lowercased().hasPrefix("userknownhostsfile") })
        XCTAssertEqual(Array(SSHFileCommand.arguments(host: "h", configFile: "/tmp/c").prefix(2)), ["-F", "/tmp/c"])
    }

    func testFailureClassification() {
        XCTAssertEqual(SSHFailure.classify(stderr: "me@h: Permission denied (publickey,password).\r\n", status: 255), .authentication)
        XCTAssertEqual(SSHFailure.classify(stderr: "No ED25519 host key is known for h and you have requested strict checking.\nHost key verification failed.\n", status: 255), .unknownHostKey)
        XCTAssertEqual(SSHFailure.classify(stderr: "@@@\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\nHost key verification failed.", status: 255), .changedHostKey)
        XCTAssertEqual(SSHFailure.classify(stderr: "ssh: Could not resolve hostname nope: nodename nor servname provided", status: 255), .unresolvedHost)
        XCTAssertEqual(SSHFailure.classify(stderr: "ssh: connect to host h port 22: Connection refused", status: 255), .refused)
        XCTAssertEqual(SSHFailure.classify(stderr: "ssh: connect to host h port 22: Operation timed out", status: 255), .timedOut)
        XCTAssertEqual(SSHFailure.classify(stderr: "subsystem request failed on channel 0", status: 255), .noSFTP)
        XCTAssertEqual(SSHFailure.classify(stderr: "first\nlast line\n", status: 1), .other("last line"))
        XCTAssertEqual(SSHFailure.classify(stderr: "", status: 255), .other("ssh exited with status 255"))
        XCTAssertTrue(SSHFailure.authentication.description.contains("never asks for passwords"))
    }

    func testPartNames() {
        let part = TransferNames.part(for: "a.txt")
        XCTAssertTrue(part.hasPrefix(".cmds-part-"))
        XCTAssertTrue(part.hasSuffix("-a.txt"))
        XCTAssertTrue(TransferNames.isPart(part))
        XCTAssertFalse(TransferNames.isPart("a.txt"))
        XCTAssertFalse(TransferNames.isPart(".cmds-part-zz"))
        XCTAssertFalse(TransferNames.isPart(".cmds-part-xyzxyzxy-a"))
        XCTAssertLessThanOrEqual(TransferNames.part(for: String(repeating: "n", count: 255)).utf8.count, 255)
    }

    func testTrashInfo() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let text = RemoteTrash.trashInfo(path: "/home/me/a b/ü.txt", date: date, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(text, "[Trash Info]\nPath=/home/me/a%20b/%C3%BC.txt\nDeletionDate=2023-11-14T22:13:20\n")
    }
}

/// SFTPClient, SFTPFileTree, RemoteTrash and TransferJob against `SFTPTestServer` on a temporary folder.
final class SFTPTransferTests: XCTestCase {
    var root: URL!
    var home: String!
    var server: SFTPTestServer!
    var remote: SFTPFileTree!
    var local: LocalFileTree!
    var localTrash: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-sftp-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        home = root.appendingPathComponent("home").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        localTrash = root.appendingPathComponent("local-trash")
        try FileManager.default.createDirectory(at: localTrash, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("mac"), withIntermediateDirectories: true)
        server = SFTPTestServer(home: home)
        remote = try server.connect()
        local = LocalFileTree()
        let trash = localTrash!
        local.trashItem = { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }
    }

    override func tearDownWithError() throws {
        server.client.disconnect()
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private var mac: String { root.appendingPathComponent("mac").path }

    private func write(_ path: String, _ text: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    private func read(_ path: String) -> String? {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).map { String(decoding: $0, as: UTF8.self) }
    }

    private func names(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
    }

    private func job(_ mode: TransferJob.Mode, _ sources: [FileLocation], to destination: FileLocation,
                     policy: TransferJob.ConflictPolicy = .ask) -> TransferJob {
        let job = TransferJob(id: 1, mode: mode, sources: sources, destination: destination, policy: policy)
        job.tree = { [remote, local] location in location.isRemote ? remote! as FileTree : local! as FileTree }
        return job
    }

    private func r(_ path: String) -> FileLocation { .remote(host: "test", path: path) }

    // MARK: - Client

    func testListStatAndRealpath() throws {
        try write(home + "/a.txt", "hello")
        try FileManager.default.createDirectory(atPath: home + "/dir", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/link", withDestinationPath: "dir")
        XCTAssertEqual(remote.home, home)
        let items = try remote.list(home).sorted { $0.name < $1.name }
        XCTAssertEqual(items.map(\.name), ["a.txt", "dir", "link"])
        XCTAssertEqual(items.map(\.kind), [.file, .folder, .symlink])
        XCTAssertEqual(items[0].size, 5)
        XCTAssertNil(try remote.item(at: home + "/missing"))
        XCTAssertEqual(try remote.client.stat(home + "/link").fileType, .folder)
        XCTAssertThrowsError(try remote.list(home + "/missing")) { error in
            XCTAssertEqual((error as? SFTPError)?.statusCode, .noSuchFile)
        }
    }

    func testPipelinedReadWithShortReplies() throws {
        var bytes = [UInt8](repeating: 0, count: 300_001)
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index * 7) }
        try Data(bytes).write(to: URL(fileURLWithPath: home + "/big.bin"))
        server.maxRead = 10_000
        let reader = try remote.openForReading(home + "/big.bin")
        var all = Data()
        while true {
            let chunk = try reader.read()
            if chunk.isEmpty { break }
            all += chunk
        }
        reader.close()
        XCTAssertEqual(all, Data(bytes))
    }

    func testCreateIsExclusiveAndRenameNeverOverwrites() throws {
        try write(home + "/taken", "old")
        XCTAssertThrowsError(try remote.createFile(home + "/taken", permissions: nil))
        let writer = try remote.createFile(home + "/new", permissions: 0o640)
        try writer.write(Data(repeating: 65, count: 100_000))
        try writer.finish()
        XCTAssertEqual(try remote.item(at: home + "/new")?.size, 100_000)
        XCTAssertThrowsError(try remote.rename(home + "/new", to: home + "/taken"))
        XCTAssertEqual(read(home + "/taken"), "old")
        XCTAssertThrowsError(try remote.removePart(home + "/taken"))
        XCTAssertEqual(server.removed, [])
    }

    func testDisconnectFailsRequestsWithReason() throws {
        server.stop()
        XCTAssertThrowsError(try remote.list(home)) { error in
            guard case .disconnected(let reason)? = error as? SFTPError else { return XCTFail("\(error)") }
            XCTAssertEqual(reason, "test server closed the connection")
        }
        XCTAssertFalse(remote.client.isConnected)
    }

    // MARK: - Remote Trash

    func testRemoteTrash() throws {
        try write(home + "/project/a.txt", "1")
        try write(home + "/other/a.txt", "2")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        remote.now = { date }
        try remote.trash(home + "/project/a.txt")
        try remote.trash(home + "/other/a.txt")
        let trash = home + "/.local/share/Trash"
        XCTAssertEqual(names(trash + "/files"), ["a 2.txt", "a.txt"])
        XCTAssertEqual(names(trash + "/info"), ["a 2.txt.trashinfo", "a.txt.trashinfo"])
        XCTAssertEqual(read(trash + "/files/a.txt"), "1")
        XCTAssertTrue(read(trash + "/info/a 2.txt.trashinfo")?.contains("Path=\(home!)/other/a.txt") == true)
        XCTAssertEqual(server.removed, [])
        // Never the Trash itself or what is in it.
        XCTAssertThrowsError(try remote.trash(home + "/.local"))
        XCTAssertThrowsError(try remote.trash(trash + "/files/a.txt"))
        // A failed rename leaves the item and removes only its own .trashinfo.
        XCTAssertThrowsError(try remote.trash(home + "/missing"))
        XCTAssertEqual(names(trash + "/info"), ["a 2.txt.trashinfo", "a.txt.trashinfo"])
    }

    // MARK: - Transfers

    func testUploadFolderKeepsContentsDatesAndLinks() throws {
        try write(mac + "/site/index.html", "<h1>")
        try write(mac + "/site/css/a.css", "body{}")
        try FileManager.default.createSymbolicLink(atPath: mac + "/site/latest", withDestinationPath: "index.html")
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: mac + "/site/index.html")
        let job = job(.copy, [.local(mac + "/site")], to: r(home))
        job.run()
        let snapshot = job.snapshot
        XCTAssertEqual(snapshot.state, .done, "\(snapshot.log)")
        XCTAssertEqual(read(home + "/site/index.html"), "<h1>")
        XCTAssertEqual(read(home + "/site/css/a.css"), "body{}")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: home + "/site/latest"), "index.html")
        let modified = try FileManager.default.attributesOfItem(atPath: home + "/site/index.html")[.modificationDate] as? Date
        XCTAssertEqual(modified, date)
        XCTAssertEqual(snapshot.progress.bytesDone, 10)
        XCTAssertEqual(snapshot.progress.bytesTotal, 10)
        XCTAssertEqual(snapshot.log.last, TransferJob.LogEntry(path: "site", outcome: .copied, date: snapshot.log.last!.date))
        XCTAssertFalse(names(home + "/site").contains { TransferNames.isPart($0) })
        XCTAssertEqual(server.removed, [])
    }

    func testDownload() throws {
        try write(home + "/logs/app.log", "line\n")
        let job = job(.copy, [r(home + "/logs/app.log")], to: .local(mac))
        job.run()
        XCTAssertEqual(job.snapshot.state, .done)
        XCTAssertEqual(read(mac + "/app.log"), "line\n")
        XCTAssertEqual(read(home + "/logs/app.log"), "line\n")
    }

    func testConflictPolicies() throws {
        try write(mac + "/a.txt", "new")
        try write(home + "/a.txt", "old")
        let skip = job(.copy, [.local(mac + "/a.txt")], to: r(home), policy: .skip)
        skip.run()
        XCTAssertEqual(skip.snapshot.log.map(\.outcome), [.skipped])
        XCTAssertEqual(read(home + "/a.txt"), "old")

        let keep = job(.copy, [.local(mac + "/a.txt")], to: r(home), policy: .keepBoth)
        keep.run()
        XCTAssertEqual(keep.snapshot.log.map(\.outcome), [.keptBoth("a 2.txt")])
        XCTAssertEqual(read(home + "/a 2.txt"), "new")

        let replace = job(.copy, [.local(mac + "/a.txt")], to: r(home), policy: .replace)
        replace.run()
        XCTAssertEqual(replace.snapshot.log.map(\.outcome), [.replaced])
        XCTAssertEqual(read(home + "/a.txt"), "new")
        // The replaced file is in the server's Trash, not deleted.
        XCTAssertEqual(read(home + "/.local/share/Trash/files/a.txt"), "old")
        XCTAssertEqual(server.removed, [])
    }

    func testConflictAskWithApplyToAll() throws {
        for name in ["a", "b", "c"] {
            try write(mac + "/\(name)", "new")
            try write(home + "/\(name)", "old")
        }
        let job = job(.copy, ["a", "b", "c"].map { .local(mac + "/\($0)") }, to: r(home))
        var asked: [String] = []
        job.onConflict = { name, isFolder, reply in
            asked.append(name)
            XCTAssertFalse(isFolder)
            reply(.keepBoth, true)
        }
        job.run()
        XCTAssertEqual(asked, ["a"])
        XCTAssertEqual(names(home), ["a", "a 2", "b", "b 2", "c", "c 2"])
    }

    func testStopEndsAsCancelled() throws {
        try write(mac + "/a", "new")
        try write(home + "/a", "old")
        let job = job(.copy, [.local(mac + "/a")], to: r(home))
        job.onConflict = { _, _, reply in reply(.stop, false) }
        job.run()
        XCTAssertEqual(job.snapshot.state, .cancelled)
        XCTAssertEqual(read(home + "/a"), "old")
    }

    func testMoveAcrossTreesTrashesOriginal() throws {
        try write(mac + "/report.pdf", "pdf")
        let job = job(.move, [.local(mac + "/report.pdf")], to: r(home))
        job.run()
        XCTAssertEqual(job.snapshot.log.map(\.outcome), [.moved])
        XCTAssertEqual(read(home + "/report.pdf"), "pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mac + "/report.pdf"))
        XCTAssertEqual(read(localTrash.appendingPathComponent("report.pdf").path), "pdf")

        // Server → Mac: the original goes to the server's Trash.
        let back = self.job(.move, [r(home + "/report.pdf")], to: .local(mac))
        back.run()
        XCTAssertEqual(back.snapshot.log.map(\.outcome), [.moved])
        XCTAssertEqual(read(mac + "/report.pdf"), "pdf")
        XCTAssertEqual(read(home + "/.local/share/Trash/files/report.pdf"), "pdf")
        XCTAssertEqual(server.removed, [])
    }

    func testMoveWithinServerIsRename() throws {
        try write(home + "/a/x.txt", "x")
        try FileManager.default.createDirectory(atPath: home + "/b", withIntermediateDirectories: true)
        let job = job(.move, [r(home + "/a/x.txt")], to: r(home + "/b"))
        job.run()
        XCTAssertEqual(job.snapshot.log.map(\.outcome), [.moved])
        XCTAssertEqual(read(home + "/b/x.txt"), "x")
        XCTAssertEqual(server.renamed.map(\.1), [home + "/b/x.txt"])
        // Into itself is refused.
        let into = self.job(.move, [r(home + "/b")], to: r(home + "/b"))
        into.run()
        XCTAssertEqual(into.snapshot.log.first?.outcome, .failed("A folder cannot be copied or moved into itself."))
    }

    func testCopyWithinSameFolderKeepsBoth() throws {
        try write(home + "/a.txt", "a")
        let job = job(.copy, [r(home + "/a.txt")], to: r(home))
        job.run()
        XCTAssertEqual(read(home + "/a 2.txt"), "a")
    }

    func testFailureRemovesOnlyPartThenRetryFillsIn() throws {
        try write(mac + "/data/one.bin", String(repeating: "1", count: 50_000))
        try write(mac + "/data/two.bin", String(repeating: "2", count: 50_000))
        server.failWritesAfter = 60_000
        let job = job(.copy, [.local(mac + "/data")], to: r(home))
        job.run()
        var snapshot = job.snapshot
        XCTAssertEqual(snapshot.state, .failed)
        XCTAssertEqual(snapshot.log.first?.path, "data/one.bin")
        XCTAssertEqual(snapshot.log.first?.outcome, .copied)
        XCTAssertEqual(snapshot.log.last?.path, "data/two.bin")
        XCTAssertEqual(names(home + "/data"), ["one.bin"])
        XCTAssertEqual(server.removed.count, 1)
        XCTAssertTrue(TransferNames.isPart(RemotePath.name(server.removed[0])))

        server.failWritesAfter = nil
        XCTAssertTrue(job.prepareRetry())
        job.run()
        snapshot = job.snapshot
        XCTAssertEqual(snapshot.state, .done, "\(snapshot.log)")
        XCTAssertEqual(names(home + "/data"), ["one.bin", "two.bin"])
        XCTAssertEqual(snapshot.log.last?.outcome, .merged)
    }

    func testCancelRemovesPartialItem() throws {
        try write(mac + "/big/a.bin", String(repeating: "x", count: 2_000_000))
        server.ioDelay = 0.01
        let job = job(.copy, [.local(mac + "/big")], to: r(home))
        let started = expectation(description: "bytes moving")
        started.assertForOverFulfill = false
        job.onChange = {
            if job.snapshot.progress.bytesDone > 100_000 { started.fulfill() }
        }
        let thread = Thread { job.run() }
        thread.start()
        wait(for: [started], timeout: 10)
        job.cancel()
        let deadline = Date().addingTimeInterval(10)
        while !job.currentState.isFinished, Date() < deadline { usleep(20_000) }
        XCTAssertEqual(job.currentState, .cancelled)
        // The part file is removed, the folder the job created went to the server's Trash.
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/big"))
        XCTAssertEqual(server.removed.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/.local/share/Trash/files/big"))
    }

    func testPauseAndResume() throws {
        try write(mac + "/a.bin", String(repeating: "x", count: 1_000_000))
        server.ioDelay = 0.005
        let job = job(.copy, [.local(mac + "/a.bin")], to: r(home))
        job.pause()
        let thread = Thread { job.run() }
        thread.start()
        usleep(300_000)
        XCTAssertEqual(job.currentState, .paused)
        XCTAssertEqual(job.snapshot.progress.bytesDone, 0)
        job.resume()
        let deadline = Date().addingTimeInterval(20)
        while !job.currentState.isFinished, Date() < deadline { usleep(20_000) }
        XCTAssertEqual(job.currentState, .done)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: home + "/a.bin")[.size] as? Int, 1_000_000)
    }

    func testConnectionDropFailsJob() throws {
        try write(mac + "/a.txt", "a")
        server.dropAfterRequests = 0
        let job = job(.copy, [.local(mac + "/a.txt")], to: r(home))
        job.run()
        XCTAssertEqual(job.snapshot.state, .failed)
        XCTAssertEqual(job.snapshot.error, "test server closed the connection")
    }

    func testQueueRunsJobsAndRetries() throws {
        try write(mac + "/a", "a")
        try write(mac + "/b", "b")
        let queue = TransferQueue(callbackQueue: DispatchQueue(label: "test"))
        let done = expectation(description: "both done")
        done.assertForOverFulfill = false
        queue.onChange = {
            if queue.snapshots.count == 2, queue.snapshots.allSatisfy({ $0.state == .done }) { done.fulfill() }
        }
        for name in ["a", "b"] {
            let job = TransferJob(id: queue.makeID(), mode: .copy, sources: [.local(mac + "/\(name)")], destination: r(home))
            job.tree = { [remote, local] location in location.isRemote ? remote! as FileTree : local! as FileTree }
            queue.add(job)
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(names(home), ["a", "b"])
        XCTAssertEqual(queue.snapshots.map(\.id), [1, 2])
        queue.clearFinished()
        XCTAssertTrue(queue.snapshots.isEmpty)
    }
}
