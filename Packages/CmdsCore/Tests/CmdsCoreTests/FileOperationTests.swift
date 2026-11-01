import Foundation
import XCTest
@testable import CmdsCore

/// Copies and moves in a temporary folder of the test's own (the "Trash" is a folder in there too).
@MainActor
final class FileOperationTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var destination: URL!
    private var trashFolder: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-fileop-\(UUID().uuidString)")
        source = root.appendingPathComponent("src")
        destination = root.appendingPathComponent("dst")
        trashFolder = root.appendingPathComponent("trash")
        for folder in [source!, destination!, trashFolder!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func names(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private struct Outcome {
        var created: [URL] = []
        var failures: [FileOperation.Failure] = []
        var cancelled = false
        var conflicts: [String] = []
        var statuses: [FileOperation.Status] = []
    }

    /// Runs the operation; conflicts are answered with `answer`.
    private func run(_ mode: FileOperation.Mode, _ items: [URL], into folder: URL? = nil,
                     answer: (FileOperation.Resolution, Bool) = (.skip, false),
                     configure: ((FileOperation) -> Void)? = nil) -> Outcome {
        let operation = FileOperation(mode: mode, sources: items, destination: folder ?? destination)
        let trashFolder = trashFolder!
        operation.trash = { url in
            try FileManager.default.moveItem(at: url, to: trashFolder.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        }
        var outcome = Outcome()
        let finished = expectation(description: "finished")
        operation.onConflict = { name, _, reply in
            outcome.conflicts.append(name)
            reply(answer.0, answer.1)
        }
        operation.onStatus = { status in outcome.statuses.append(status) }
        operation.onFinish = { created, failures, cancelled in
            outcome.created = created
            outcome.failures = failures
            outcome.cancelled = cancelled
            finished.fulfill()
        }
        configure?(operation)
        operation.start()
        wait(for: [finished], timeout: 30)
        return outcome
    }

    func testCopiesFilesAndFoldersWithTheirContents() throws {
        try write("a", source.appendingPathComponent("a.txt"))
        try write("deep", source.appendingPathComponent("folder/sub/deep.txt"))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("folder/link").path,
                                                   withDestinationPath: "sub/deep.txt")
        let outcome = run(.copy, [source.appendingPathComponent("a.txt"), source.appendingPathComponent("folder")])
        XCTAssertTrue(outcome.failures.isEmpty, "\(outcome.failures)")
        XCTAssertFalse(outcome.cancelled)
        XCTAssertEqual(outcome.created.map(\.lastPathComponent), ["a.txt", "folder"])
        XCTAssertEqual(read(destination.appendingPathComponent("a.txt")), "a")
        XCTAssertEqual(read(destination.appendingPathComponent("folder/sub/deep.txt")), "deep")
        // Links stay links.
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("folder/link").path),
                       "sub/deep.txt")
        XCTAssertEqual(read(source.appendingPathComponent("a.txt")), "a", "the original stays")
    }

    func testCopyIntoItsOwnFolderKeepsBoth() throws {
        try write("a", source.appendingPathComponent("a.txt"))
        let outcome = run(.copy, [source.appendingPathComponent("a.txt")], into: source)
        XCTAssertTrue(outcome.conflicts.isEmpty)
        XCTAssertEqual(names(source), ["a 2.txt", "a.txt"])
    }

    func testConflictKeepBothSkipReplace() throws {
        try write("new", source.appendingPathComponent("a.txt"))
        try write("old", destination.appendingPathComponent("a.txt"))
        let item = [source.appendingPathComponent("a.txt")]

        var outcome = run(.copy, item, answer: (.keepBoth, false))
        XCTAssertEqual(outcome.conflicts, ["a.txt"])
        XCTAssertEqual(names(destination), ["a 2.txt", "a.txt"])
        XCTAssertEqual(read(destination.appendingPathComponent("a 2.txt")), "new")

        outcome = run(.copy, item, answer: (.skip, false))
        XCTAssertEqual(names(destination), ["a 2.txt", "a.txt"])
        XCTAssertEqual(read(destination.appendingPathComponent("a.txt")), "old")

        outcome = run(.copy, item, answer: (.replace, false))
        XCTAssertEqual(read(destination.appendingPathComponent("a.txt")), "new")
        // The replaced item went to the Trash, not away for good.
        XCTAssertEqual(names(trashFolder).count, 1)
        XCTAssertEqual(read(trashFolder.appendingPathComponent(names(trashFolder)[0])), "old")
    }

    func testApplyToAllAsksOnce() throws {
        for name in ["a.txt", "b.txt"] {
            try write("new", source.appendingPathComponent(name))
            try write("old", destination.appendingPathComponent(name))
        }
        let outcome = run(.copy, [source.appendingPathComponent("a.txt"), source.appendingPathComponent("b.txt")],
                          answer: (.keepBoth, true))
        XCTAssertEqual(outcome.conflicts, ["a.txt"])
        XCTAssertEqual(names(destination), ["a 2.txt", "a.txt", "b 2.txt", "b.txt"])
    }

    func testStopEndsTheOperation() throws {
        try write("new", source.appendingPathComponent("a.txt"))
        try write("x", source.appendingPathComponent("b.txt"))
        try write("old", destination.appendingPathComponent("a.txt"))
        let outcome = run(.copy, [source.appendingPathComponent("a.txt"), source.appendingPathComponent("b.txt")],
                          answer: (.stop, false))
        XCTAssertTrue(outcome.cancelled)
        XCTAssertEqual(names(destination), ["a.txt"])
    }

    func testMoveWithinAVolumeRenames() throws {
        try write("a", source.appendingPathComponent("folder/a.txt"))
        let outcome = run(.move, [source.appendingPathComponent("folder")])
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(names(source), [])
        XCTAssertEqual(read(destination.appendingPathComponent("folder/a.txt")), "a")
        XCTAssertEqual(names(trashFolder), [], "a rename puts nothing in the Trash")
    }

    func testMoveIntoItsOwnFolderDoesNothing() throws {
        try write("a", source.appendingPathComponent("a.txt"))
        let outcome = run(.move, [source.appendingPathComponent("a.txt")], into: source)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(names(source), ["a.txt"])
    }

    func testFolderIntoItselfIsRefused() throws {
        try write("a", source.appendingPathComponent("folder/inner/a.txt"))
        let folder = source.appendingPathComponent("folder")
        let outcome = run(.copy, [folder], into: folder.appendingPathComponent("inner"))
        XCTAssertEqual(outcome.failures.map(\.reason), [.intoItself])
        XCTAssertEqual(names(folder.appendingPathComponent("inner")), ["a.txt"])
    }

    func testCancelLeavesNoPartialCopy() throws {
        // Large enough for several progress callbacks.
        let big = source.appendingPathComponent("big.bin")
        try Data(count: 64 * 1024 * 1024).write(to: big)
        let outcome = run(.copy, [big]) { operation in
            operation.onCopyProgress = { [weak operation] bytes in
                if bytes > 0 { operation?.cancel() }
            }
        }
        let copy = destination.appendingPathComponent("big.bin")
        XCTAssertTrue(outcome.cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "the partial copy is removed")
        XCTAssertTrue(outcome.created.isEmpty)
    }

    func testCancelledBeforeStartDoesNothing() throws {
        try write("a", source.appendingPathComponent("a.txt"))
        let outcome = run(.copy, [source.appendingPathComponent("a.txt")]) { $0.cancel() }
        XCTAssertTrue(outcome.cancelled)
        XCTAssertEqual(names(destination), [])
    }

    func testStatusCountsTheBytesOfSkippedAndCopiedItems() throws {
        try write("12345", source.appendingPathComponent("a.txt"))
        try write("123", source.appendingPathComponent("folder/b.txt"))
        try write("old", destination.appendingPathComponent("a.txt"))
        let outcome = run(.copy, [source.appendingPathComponent("a.txt"), source.appendingPathComponent("folder")],
                          answer: (.skip, false))
        XCTAssertEqual(outcome.conflicts, ["a.txt"])
        let last = try XCTUnwrap(outcome.statuses.last)
        XCTAssertEqual(last.mode, .copy)
        XCTAssertEqual(last.count, 2)
        XCTAssertEqual(last.index, 2)
        XCTAssertEqual(last.name, "folder")
        XCTAssertEqual(last.bytesTotal, 8)
        XCTAssertEqual(last.bytesDone, 8)
        XCTAssertEqual(outcome.statuses.first?.index, 1)
        XCTAssertEqual(outcome.statuses.first?.name, "a.txt")
    }

    func testMoveWithinAVolumeCountsNoBytes() throws {
        try write("12345", source.appendingPathComponent("a.txt"))
        let outcome = run(.move, [source.appendingPathComponent("a.txt")])
        XCTAssertEqual(outcome.statuses.last?.bytesTotal, 0)
        XCTAssertEqual(outcome.statuses.last?.bytesDone, 0)
    }

    func testReplacingTheFolderTheItemComesFromIsRefused() throws {
        // dst/folder/folder moved into dst: replacing dst/folder would trash the item itself.
        try write("a", destination.appendingPathComponent("folder/folder/a.txt"))
        let inner = destination.appendingPathComponent("folder/folder")
        let outcome = run(.move, [inner], answer: (.replace, false))
        XCTAssertEqual(outcome.failures.map(\.reason), [.replaceContainsSource])
        XCTAssertEqual(read(inner.appendingPathComponent("a.txt")), "a")
        XCTAssertEqual(names(trashFolder), [])
    }

    func testReplaceFailsWhenTheTrashFails() throws {
        try write("new", source.appendingPathComponent("a.txt"))
        try write("old", destination.appendingPathComponent("a.txt"))
        struct TrashError: LocalizedError { var errorDescription: String? { "no trash" } }
        let outcome = run(.copy, [source.appendingPathComponent("a.txt")], answer: (.replace, false)) { operation in
            operation.trash = { _ in throw TrashError() }
        }
        XCTAssertEqual(outcome.failures.map(\.reason), [.error("no trash")])
        XCTAssertEqual(read(destination.appendingPathComponent("a.txt")), "old")
    }

    func testByteCountExistsAndVolume() throws {
        try write("12345", source.appendingPathComponent("folder/a.txt"))
        try write("123", source.appendingPathComponent("folder/inner/b.txt"))
        let link = source.appendingPathComponent("folder/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertEqual(FileOperation.byteCount(source.appendingPathComponent("folder")), 8, "links are not followed")
        XCTAssertEqual(FileOperation.byteCount(source.appendingPathComponent("folder/a.txt")), 5)
        XCTAssertEqual(FileOperation.byteCount(source.appendingPathComponent("none")), 0)
        XCTAssertTrue(FileOperation.exists(link), "a link whose target is missing exists")
        XCTAssertFalse(FileOperation.exists(source.appendingPathComponent("none")))
        XCTAssertNotNil(FileOperation.volume(of: source))
        XCTAssertEqual(FileOperation.volume(of: source.appendingPathComponent("not yet")), FileOperation.volume(of: source))
    }
}
