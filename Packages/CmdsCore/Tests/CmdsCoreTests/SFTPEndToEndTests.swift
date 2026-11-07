import XCTest
@testable import CmdsCore

/// `SSHFileConnection` through the real `ssh` against a throwaway sshd (docs/internals/testing.md "Files panes on SSH
/// hosts"): `Packages/CmdsSSH/Scripts/test-relay-sshd.sh start <dir> <port>`, then
/// `CMDS_FILES_E2E_DIR=<dir> swift test --filter SFTPEndToEndTests`. Skipped without it; never uses ~/.ssh.
final class SFTPEndToEndTests: XCTestCase {
    var directory: String!
    var config: String { directory + "/ssh_config" }

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["CMDS_FILES_E2E_DIR"] else {
            throw XCTSkip("set CMDS_FILES_E2E_DIR to a test-relay-sshd.sh directory")
        }
        directory = dir
    }

    func testConnectListAndTransfer() throws {
        let connection = try SSHFileConnection(host: "cmds-test-relay", configFile: config)
        defer { connection.close() }
        // The script starts SFTP in <dir>/sftp-home, so nothing outside the test directory is touched.
        XCTAssertEqual(connection.home, realpath(directory + "/sftp-home", nil).map { String(cString: $0) })
        let work = connection.home + "/work-\(UUID().uuidString)"
        let remote = SFTPFileTree(client: connection.client, home: connection.home)
        try remote.makeFolder(work, permissions: 0o700)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-e2e-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: local + "/up/sub", withIntermediateDirectories: true)
        let payload = Data((0..<700_000).map { UInt8(truncatingIfNeeded: $0 * 31) })
        try payload.write(to: URL(fileURLWithPath: local + "/up/sub/blob.bin"))
        defer { try? FileManager.default.removeItem(atPath: local) }

        let upload = TransferJob(id: 1, mode: .copy, sources: [.local(local + "/up")],
                                 destination: .remote(host: "cmds-test-relay", path: work))
        upload.tree = { location in location.isRemote ? remote as FileTree : LocalFileTree() }
        upload.run()
        XCTAssertEqual(upload.snapshot.state, .done, "\(upload.snapshot.log)")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: work + "/up/sub/blob.bin")), payload)
        XCTAssertEqual(try remote.list(work + "/up/sub").map(\.name), ["blob.bin"])

        try FileManager.default.createDirectory(atPath: local + "/down", withIntermediateDirectories: true)
        let download = TransferJob(id: 2, mode: .copy, sources: [.remote(host: "cmds-test-relay", path: work + "/up/sub/blob.bin")],
                                   destination: .local(local + "/down"))
        download.tree = upload.tree
        download.run()
        XCTAssertEqual(download.snapshot.state, .done)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: local + "/down/blob.bin")), payload)
    }

    /// Editing a server's file over real ssh and OpenSSH's sftp server (which offers `posix-rename@openssh.com`).
    func testEditAndSave() throws {
        let connection = try SSHFileConnection(host: "cmds-test-relay", configFile: config)
        defer { connection.close() }
        XCTAssertNotNil(connection.client.extensions[SFTPClient.posixRenameExtension])
        let remote = SFTPFileTree(client: connection.client, home: connection.home)
        let work = connection.home + "/edit-\(UUID().uuidString)"
        try remote.makeFolder(work, permissions: 0o700)
        let file = work + "/notes.txt"
        try Data("old".utf8).write(to: URL(fileURLWithPath: file))
        chmod(file, 0o640)
        let edits = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-e2e-edit-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: edits, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: edits) }
        let copy = edits + "/notes.txt"

        let downloaded = try RemoteEditCopy.download(file, from: remote, to: copy)
        XCTAssertEqual(try String(contentsOfFile: copy, encoding: .utf8), "old")
        try Data("edited".utf8).write(to: URL(fileURLWithPath: copy))
        let tree: (FileLocation) throws -> FileTree = { $0.isRemote ? remote : LocalFileTree() }
        let save = TransferJob(id: 1, saving: .local(copy), to: .remote(host: "cmds-test-relay", path: work),
                               .init(name: "notes.txt", base: downloaded.version))
        save.tree = tree
        save.onConflict = { _, _, reply in
            XCTFail("unchanged on the server")
            reply(.stop, false)
        }
        save.run()
        XCTAssertEqual(save.snapshot.log.map(\.outcome), [.saved])
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "edited")
        XCTAssertEqual(try remote.item(at: file)?.permissions, 0o640)
        XCTAssertEqual(try remote.list(work).map(\.name), ["notes.txt"])

        // Changed on the server: asked; Keep Theirs brings it into the copy.
        try Data("theirs, longer".utf8).write(to: URL(fileURLWithPath: file))
        try Data("mine".utf8).write(to: URL(fileURLWithPath: copy))
        let conflict = TransferJob(id: 2, saving: .local(copy), to: .remote(host: "cmds-test-relay", path: work),
                                   .init(name: "notes.txt", base: save.snapshot.saved!.version))
        conflict.tree = tree
        var asked = 0
        conflict.onConflict = { _, _, reply in
            asked += 1
            reply(.skip, false)
        }
        conflict.run()
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(conflict.snapshot.log.map(\.outcome), [.keptTheirs])
        XCTAssertEqual(try String(contentsOfFile: copy, encoding: .utf8), "theirs, longer")
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "theirs, longer")
    }

    func testRefusals() throws {
        let emptyKnownHosts = directory + "/known_hosts_empty"
        for (host, expected) in [("cmds-test-unknown", SSHFailure.unknownHostKey),
                                 ("cmds-test-changed", .changedHostKey),
                                 ("cmds-test-nokey", .authentication)] {
            XCTAssertThrowsError(try SSHFileConnection(host: host, configFile: config), host) { error in
                XCTAssertEqual((error as? SSHConnectError)?.failure, expected, "\(host): \(error)")
            }
        }
        // StrictHostKeyChecking=yes on the command line wins over accept-new in the config: nothing was added.
        XCTAssertEqual(try String(contentsOfFile: emptyKnownHosts, encoding: .utf8), "")
    }
}
