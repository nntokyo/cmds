import XCTest
@testable import CmdsCore

final class StoredFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("StoredFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private struct Item: Codable, Equatable { var name: String }

    /// 2026-10-30T12:34:56Z
    private let now = Date(timeIntervalSince1970: 1_793_363_696)

    func testMissingFile() {
        let url = directory.appendingPathComponent("store.json")
        guard case .missing = StoredFile.load([Item].self, from: url) else { return XCTFail("expected .missing") }
    }

    func testLoadsValidFile() throws {
        let url = directory.appendingPathComponent("store.json")
        try JSONEncoder().encode([Item(name: "a")]).write(to: url)
        guard case .loaded(let items) = StoredFile.load([Item].self, from: url) else { return XCTFail("expected .loaded") }
        XCTAssertEqual(items, [Item(name: "a")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testCorruptFileIsMovedAsideAndKept() throws {
        let url = directory.appendingPathComponent("store.json")
        let original = Data("{ not json".utf8)
        try original.write(to: url)

        guard case .unreadable(_, .success(let backup)) = StoredFile.load([Item].self, from: url, now: now) else {
            return XCTFail("expected .unreadable with a backup")
        }
        XCTAssertEqual(backup.lastPathComponent, "store.json.corrupt-20261030T123456Z")
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // A later save writes a new file; the backup is untouched.
        try JSONEncoder().encode([Item]()).write(to: url, options: .atomic)
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }

    func testWrongShapeIsTreatedAsCorrupt() throws {
        let url = directory.appendingPathComponent("store.json")
        try Data(#"{"name": "not an array"}"#.utf8).write(to: url)
        guard case .unreadable(_, .success) = StoredFile.load([Item].self, from: url, now: now) else {
            return XCTFail("expected .unreadable")
        }
    }

    func testMoveAsideDoesNotOverwriteEarlierBackup() throws {
        let url = directory.appendingPathComponent("store.json")
        try Data("first".utf8).write(to: url)
        let first = try StoredFile.moveAside(url, now: now)
        try Data("second".utf8).write(to: url)
        let second = try StoredFile.moveAside(url, now: now)

        XCTAssertEqual(second.lastPathComponent, "store.json.corrupt-20261030T123456Z-2")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second")
    }

    func testFailedMoveLeavesFileInPlace() throws {
        let url = directory.appendingPathComponent("store.json")
        try Data("{ not json".utf8).write(to: url)
        // A read-only directory: the file can be read but not renamed.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        guard case .unreadable(_, .failure) = StoredFile.load([Item].self, from: url, now: now) else {
            return XCTFail("expected .unreadable with a move failure")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testUnreadableFileStaysInPlace() throws {
        let url = directory.appendingPathComponent("store.json")
        try JSONEncoder().encode([Item(name: "a")]).write(to: url)
        // Not readable (e.g. permissions): the content may be fine, so it is neither moved nor reported missing.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }

        guard case .unreadable(_, .failure) = StoredFile.load([Item].self, from: url, now: now) else {
            return XCTFail("expected .unreadable with the file kept in place")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains(".corrupt-") }
        XCTAssertEqual(backups, [])
    }
}
