import XCTest
@testable import CmdsCore

/// Browsing a files pane's folders on the phone (`SyncFeature.filesBrowse`, #26 phase 4): the messages, the listing
/// (order, cap, hidden items, links), paths and the files sent.
final class SyncListingTests: XCTestCase {
    let codec = SyncCodec()
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-listing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, _ text: String = "x") throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func folder(_ name: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }

    // MARK: - Messages

    func testRequestListingRoundTrip() throws {
        for message: ClientMessage in [.requestListing(.init(paneID: "p1")),
                                        .requestListing(.init(paneID: "p1", path: "/Users/me/src")),
                                        .requestFile(.init(paneID: "p1", path: "/Users/me/a.png"))] {
            XCTAssertEqual(try codec.decodeClientMessage(codec.encode(message)), message)
        }
        let json = String(decoding: try codec.encode(.requestListing(.init(paneID: "p1"))), as: UTF8.self)
        XCTAssertEqual(json, #"{"paneID":"p1","type":"requestListing"}"#, "no path: the pane's folder")
    }

    func testOldRequestFileHasNoPath() throws {
        // Phones before filesBrowse send only the pane; the Mac sends that preview pane's file.
        let decoded = try codec.decodeClientMessage(Data(#"{"type":"requestFile","paneID":"p1"}"#.utf8))
        XCTAssertEqual(decoded, .requestFile(.init(paneID: "p1")))
        let json = String(decoding: try codec.encode(.requestFile(.init(paneID: "p1"))), as: UTF8.self)
        XCTAssertFalse(json.contains("path"), json)
    }

    func testListingRoundTripWithEpochDates() throws {
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let listing = ServerMessage.Listing(paneID: "p1", path: "/Users/me", entries: [
            SyncFileEntry(name: "src", kind: .folder, modified: date),
            SyncFileEntry(name: "link", kind: .symlink, linksToFolder: true, modified: date),
            SyncFileEntry(name: "a.png", kind: .file, size: 1234, modified: date),
        ], truncated: true)
        let data = try codec.encode(.listing(listing))
        XCTAssertEqual(try codec.decodeServerMessage(data), .listing(listing))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains(#""modified":1793000000"#), json)
        XCTAssertTrue(json.contains(#""type":"listing""#), json)
    }

    func testListingDecodesLeniently() throws {
        // A newer Mac: an unknown kind, an unknown field, an entry this build cannot read, an unknown error.
        let json = #"""
        {"type":"listing","paneID":"p1","path":"/x","future":1,"error":"diskOnFire","entries":[
          {"name":"a","kind":"socketish","size":"12"},
          {"kind":"file"},
          {"name":"b","kind":"file","size":5,"modified":1793000000,"xattrs":{}}
        ]}
        """#
        guard case .listing(let listing) = try codec.decodeServerMessage(Data(json.utf8)) else {
            return XCTFail("not a listing")
        }
        XCTAssertEqual(listing.entries.map(\.name), ["a", "b"])
        XCTAssertEqual(listing.entries[0].kind, .other)
        XCTAssertEqual(listing.entries[0].size, 12)
        XCTAssertEqual(listing.entries[1].modified, Date(timeIntervalSince1970: 1_793_000_000))
        XCTAssertEqual(listing.error, "diskOnFire")
        XCTAssertEqual(listing.failure, .other)
        XCTAssertNil(listing.truncated)
    }

    func testFilePiecesCarryThePath() throws {
        let pieces = SyncFile.messages(paneID: "p1", name: "a.png", mime: "image/png",
                                       data: Data(count: SyncFile.chunkBytes + 1), path: "/x/a.png")
        XCTAssertEqual(pieces.count, 2)
        XCTAssertTrue(pieces.allSatisfy { $0.path == "/x/a.png" })
        let decoded = try codec.decodeServerMessage(codec.encode(.file(pieces[1])))
        XCTAssertEqual(decoded, .file(pieces[1]))
        // Preview panes: no path, as before.
        let preview = SyncFile.messages(paneID: "p1", name: "a.png", mime: "image/png", data: Data([1]))
        XCTAssertFalse(String(decoding: try codec.encode(.file(preview[0])), as: UTF8.self).contains("path"))
    }

    func testFeatureIsOptional() throws {
        // Older Macs list no filesBrowse; older phones decode a welcome that has it.
        let welcome = ServerMessage.welcome(.init(macName: "Mac", token: "t", features: [SyncFeature.filesBrowse]))
        XCTAssertEqual(try codec.decodeServerMessage(codec.encode(welcome)), welcome)
        XCTAssertEqual(SyncFeature.filesBrowse, "filesBrowse")
    }

    // MARK: - Paths

    func testPathsAreAbsoluteAndStandardized() throws {
        XCTAssertEqual(try SyncListing.path(requested: nil, paneFolder: "/Users/me/src/"), "/Users/me/src")
        XCTAssertEqual(try SyncListing.path(requested: "/Users/me/src/../docs/./a", paneFolder: "/x"), "/Users/me/docs/a")
        XCTAssertEqual(try SyncListing.path(requested: "/../..", paneFolder: "/x"), "/")
        XCTAssertEqual(try SyncListing.path(requested: "//tmp///x", paneFolder: "/x"), "/tmp/x")
        for bad in ["relative/path", "~/src", "", "/a\u{0}b", "/a\nb"] {
            XCTAssertThrowsError(try SyncListing.path(requested: bad, paneFolder: "/x"), bad) { error in
                XCTAssertEqual(SyncListing.failure(for: error), .badPath)
            }
        }
    }

    // MARK: - Entries

    func testEntriesFoldersFirstThenNamesLikeTheMac() {
        let items = [FileItem(name: "file10.txt", kind: .file, size: 3), FileItem(name: "b", kind: .folder),
                     FileItem(name: "file2.txt", kind: .file, size: 2), FileItem(name: "A", kind: .folder),
                     FileItem(name: "link", kind: .symlink), FileItem(name: "fifo", kind: .other)]
        let (entries, truncated) = SyncListing.entries(items, showHidden: false, follow: { item in
            item.name == "link" ? FileItem(name: "target", kind: .folder) : nil
        })
        XCTAssertFalse(truncated)
        XCTAssertEqual(entries.map(\.name), ["A", "b", "link", "fifo", "file2.txt", "file10.txt"])
        XCTAssertEqual(entries[2].linksToFolder, true)
        XCTAssertTrue(entries[2].opensAsFolder)
        XCTAssertNil(entries[0].size, "folders have no size")
        XCTAssertEqual(entries[4].size, 2)
    }

    func testEntriesHideDotFilesUnlessShown() {
        let items = [FileItem(name: ".git", kind: .folder), FileItem(name: ".zshrc", kind: .file),
                     FileItem(name: "README", kind: .file), FileItem(name: "Icon\r", kind: .file)]
        let hidden: (FileItem) -> Bool = { $0.name.hasPrefix(".") || $0.name == "Icon\r" }
        XCTAssertEqual(SyncListing.entries(items, showHidden: false, isHidden: hidden).entries.map(\.name), ["README"])
        let shown = SyncListing.entries(items, showHidden: true, isHidden: hidden).entries.map(\.name)
        XCTAssertEqual(Set(shown), [".git", ".zshrc", "Icon\r", "README"])
        XCTAssertEqual(shown.first, ".git")
    }

    func testEntriesAreCapped() {
        let items = (0..<25).map { FileItem(name: "f\($0)", kind: .file) } + [FileItem(name: "zz", kind: .folder)]
        let (entries, truncated) = SyncListing.entries(items, showHidden: false, limit: 10)
        XCTAssertTrue(truncated)
        XCTAssertEqual(entries.count, 10)
        XCTAssertEqual(entries.first?.name, "zz", "folders come first, also when the list is cut")
        XCTAssertEqual(entries.last?.name, "f8")
        XCTAssertFalse(SyncListing.entries(items, showHidden: false, limit: 26).truncated)
    }

    func testEntriesDropNamesThatCouldEscape() {
        let items = [FileItem(name: "..", kind: .folder), FileItem(name: "a/b", kind: .file), FileItem(name: "ok", kind: .file)]
        XCTAssertEqual(SyncListing.entries(items, showHidden: true).entries.map(\.name), ["ok"])
    }

    // MARK: - Reading on this Mac

    func testLocalListing() throws {
        try folder("src")
        try write("b.txt", "hello")
        try write(".hidden")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("to-src").path,
                                                   withDestinationPath: root.appendingPathComponent("src").path)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("broken").path,
                                                   withDestinationPath: "/nonexistent/\(UUID().uuidString)")
        let reader = SyncFolderReader.local()
        let path = try reader.path(requested: nil, paneFolder: root.path + "/")
        let listing = reader.listing(paneID: "p1", path: path, showHidden: false)
        XCTAssertNil(listing.error)
        XCTAssertEqual(listing.path, root.path)
        XCTAssertEqual(listing.entries.map(\.name), ["src", "to-src", "b.txt", "broken"])
        XCTAssertEqual(listing.entries[1].kind, .symlink)
        XCTAssertEqual(listing.entries[1].linksToFolder, true)
        XCTAssertEqual(listing.entries[2].size, 5)
        XCTAssertNotNil(listing.entries[2].modified)
        XCTAssertNil(listing.entries[3].linksToFolder)
        XCTAssertTrue(reader.listing(paneID: "p1", path: path, showHidden: true).entries.contains { $0.name == ".hidden" })
    }

    func testLocalListingFailures() throws {
        try write("file.txt")
        let reader = SyncFolderReader.local()
        XCTAssertEqual(reader.listing(paneID: "p1", path: root.path + "/missing", showHidden: false).failure, .notFound)
        let notFolder = reader.listing(paneID: "p1", path: root.path + "/file.txt", showHidden: false)
        XCTAssertEqual(notFolder.failure, .notAFolder)
        XCTAssertEqual(notFolder.path, root.path + "/file.txt")
        XCTAssertTrue(notFolder.entries.isEmpty)
    }

    func testLocalFileIsSentWithItsPath() throws {
        try write("notes/a.md", "# Hi")
        let reader = SyncFolderReader.local()
        let path = root.path + "/notes/a.md"
        let pieces = try reader.file(paneID: "p1", path: path)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].name, "a.md")
        XCTAssertEqual(pieces[0].mime, "text/markdown")
        XCTAssertEqual(pieces[0].path, path)
        XCTAssertEqual(pieces[0].data, Data("# Hi".utf8))
        XCTAssertThrowsError(try reader.file(paneID: "p1", path: root.path + "/notes")) { error in
            XCTAssertEqual(SyncListing.failure(for: error), .notAFile)
        }
        XCTAssertThrowsError(try reader.file(paneID: "p1", path: root.path + "/nope")) { error in
            XCTAssertEqual(SyncListing.failure(for: error), .notFound)
        }
    }

    func testLargeFileIsTruncated() throws {
        let url = root.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(SyncFile.maxBytes + 1))
        try handle.close()
        let pieces = try SyncFolderReader.local().file(paneID: "p1", path: url.path)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].truncated, true)
        XCTAssertEqual(pieces[0].path, url.path)
        XCTAssertTrue(pieces[0].data.isEmpty)
    }

    func testPipeIsNotRead() throws {
        // Reading a FIFO would block the Mac's reader forever.
        let path = root.path + "/pipe"
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        XCTAssertThrowsError(try SyncFolderReader.local().file(paneID: "p1", path: path)) { error in
            XCTAssertEqual(SyncListing.failure(for: error), .notAFile)
        }
        let listing = SyncFolderReader.local().listing(paneID: "p1", path: root.path, showHidden: false)
        XCTAssertEqual(listing.entries.first { $0.name == "pipe" }?.kind, .other)
    }

    func testPermissionDenied() throws {
        try folder("locked")
        let locked = root.appendingPathComponent("locked").path
        XCTAssertEqual(chmod(locked, 0), 0)
        defer { chmod(locked, 0o755) }
        let listing = SyncFolderReader.local().listing(paneID: "p1", path: locked, showHidden: false)
        XCTAssertEqual(listing.failure, .permissionDenied)
    }
}
