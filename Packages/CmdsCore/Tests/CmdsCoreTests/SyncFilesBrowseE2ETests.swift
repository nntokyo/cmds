import Foundation
import XCTest
@testable import CmdsCore

/// Browsing a files pane from the phone (`SyncFeature.filesBrowse`, #26 phase 4) end to end against an isolated
/// instance (docs/internals/testing.md "Sync against an isolated instance"): set `CMDS_FILES_E2E_PAIRING` to its
/// `sync-test-pairing.txt`. The test makes a temporary folder, opens it in a files pane through the instance's socket,
/// lists it and a subfolder from a phone with the feature, fetches a file, checks the errors, and that a phone without
/// the feature is refused. It closes the workspace and removes the folder at the end.
final class SyncFilesBrowseE2ETests: XCTestCase {
    private func listing(_ phone: SyncE2EPhone, timeout: TimeInterval = 10) throws -> ServerMessage.Listing {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .listing(let listing) = try phone.next(timeout: max(0.1, deadline.timeIntervalSinceNow)) {
                return listing
            }
        }
        throw SyncE2EFailure("no listing")
    }

    private func fileOrError(_ phone: SyncE2EPhone, timeout: TimeInterval = 10) throws
        -> Result<[ServerMessage.File], SyncE2EFailure> {
        let deadline = Date().addingTimeInterval(timeout)
        var pieces: [ServerMessage.File] = []
        while Date() < deadline {
            switch try phone.next(timeout: max(0.1, deadline.timeIntervalSinceNow)) {
            case .file(let piece):
                pieces.append(piece)
                if piece.truncated == true || pieces.reduce(0, { $0 + $1.data.count }) >= piece.size {
                    return .success(pieces)
                }
            case .error(let error):
                return .failure(SyncE2EFailure("\(error.code) \(error.message)"))
            default:
                continue
            }
        }
        throw SyncE2EFailure("no file")
    }

    func testPhoneBrowsesAFilesPaneReadOnly() throws {
        let instance = try SyncE2EInstance(pairingVariable: "CMDS_FILES_E2E_PAIRING")
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/tmp/cmds-files-e2e-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: root.appendingPathComponent("sub/deeper"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("hello from the Mac\n".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try Data("x".utf8).write(to: root.appendingPathComponent(".hidden"))
        try Data(count: 3000).write(to: root.appendingPathComponent("sub/blob.bin"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "sub")

        let (workspaceID, shellPane) = try instance.createWorkspace(title: "files e2e")
        defer { instance.closeWorkspace(workspaceID) }
        let opened = try instance.api.call("files.open", params: ["pane": .string(shellPane), "path": .string(root.path),
                                                                   "focus": false])
        let paneID = try XCTUnwrap(opened["id"]?.stringValue)

        let phone = try SyncE2EPhone(instance, hello: .init(deviceName: "files test", deviceID: "files-test",
                                                            features: [SyncFeature.filesBrowse],
                                                            pairingCode: instance.payload.code))
        XCTAssertEqual(phone.welcome.features?.contains(SyncFeature.filesBrowse), true)

        // The pane's folder: folders (and the link to one) first, no hidden item.
        try phone.send(.requestListing(.init(paneID: paneID)))
        let top = try listing(phone)
        XCTAssertNil(top.error)
        XCTAssertEqual(top.path, RemotePath.normalized(root.path))
        XCTAssertEqual(top.entries.map(\.name), ["link", "sub", "notes.txt"])
        XCTAssertEqual(top.entries.first?.opensAsFolder, true)
        XCTAssertEqual(top.entries.last?.size, 19)

        // A subfolder, through the path the phone builds.
        try phone.send(.requestListing(.init(paneID: paneID, path: top.path + "/sub")))
        let sub = try listing(phone)
        XCTAssertEqual(sub.entries.map(\.name), ["deeper", "blob.bin"])
        XCTAssertEqual(sub.entries.last?.size, 3000)

        // A file, and a folder asked for as a file.
        try phone.send(.requestFile(.init(paneID: paneID, path: top.path + "/notes.txt")))
        let pieces = try fileOrError(phone).get()
        XCTAssertEqual(String(decoding: pieces.flatMap(\.data), as: UTF8.self), "hello from the Mac\n")
        XCTAssertEqual(pieces.first?.path, top.path + "/notes.txt")
        try phone.send(.requestFile(.init(paneID: paneID, path: top.path + "/sub")))
        if case .success = try fileOrError(phone) { XCTFail("a folder was sent as a file") }

        // Errors: a missing folder, a relative path, a pane that is not a files pane.
        try phone.send(.requestListing(.init(paneID: paneID, path: top.path + "/missing")))
        XCTAssertEqual(try listing(phone).failure, .notFound)
        try phone.send(.requestListing(.init(paneID: paneID, path: "relative")))
        XCTAssertEqual(try listing(phone).failure, .badPath)
        try phone.send(.requestListing(.init(paneID: shellPane)))
        XCTAssertEqual(try listing(phone).failure, .notFilesPane)

        // Nothing changed on the Mac: the pane still shows its folder.
        let panes = try instance.api.call("pane.list", params: ["workspace": .string(workspaceID)])
        let pane = panes.arrayValue?.first { $0["id"]?.stringValue == paneID }
        XCTAssertEqual(pane?["workingDirectory"]?.stringValue.map(RemotePath.normalized), top.path)

        // A phone without the feature is refused.
        let older = try SyncE2EPhone(instance, hello: .init(deviceName: "files old test", deviceID: "files-old-test",
                                                            token: phone.welcome.token))
        try older.send(.requestListing(.init(paneID: paneID)))
        let deadline = Date().addingTimeInterval(5)
        var refused = false
        while Date() < deadline, !refused {
            switch try older.next(timeout: max(0.1, deadline.timeIntervalSinceNow)) {
            case .error(let error): refused = error.code == .badRequest
            case .listing: XCTFail("a phone without filesBrowse got a listing")
            default: continue
            }
        }
        XCTAssertTrue(refused)
    }
}
