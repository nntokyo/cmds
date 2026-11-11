import Foundation
import XCTest
@testable import CmdsCore

/// Exporting a pane's scrollback (#253): path checks, the 0600 file, and the export in chunks.
final class ScrollbackExportTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Paths

    func testPathMustBeAbsoluteInAnExistingFolderAndNew() throws {
        let file = folder.appendingPathComponent("out.txt").path
        XCTAssertEqual(try ScrollbackExport.validatedPath(file, force: false), file)
        XCTAssertEqual(try ScrollbackExport.validatedPath(folder.path + "/x/../out.txt", force: false), file)
        for bad in ["out.txt", "~/out.txt", "./out.txt", "", folder.path, folder.path + "/", "/",
                    folder.path + "/missing/out.txt"] {
            XCTAssertThrowsError(try ScrollbackExport.validatedPath(bad, force: true), bad)
        }
        FileManager.default.createFile(atPath: file, contents: Data("old".utf8))
        XCTAssertThrowsError(try ScrollbackExport.validatedPath(file, force: false)) { error in
            XCTAssertTrue((error as? RPCError)?.message.contains("use force") == true)
        }
        XCTAssertEqual(try ScrollbackExport.validatedPath(file, force: true), file)
        // A symlink counts as existing, even a dangling one.
        let link = folder.appendingPathComponent("link.txt").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: folder.appendingPathComponent("nowhere").path)
        XCTAssertThrowsError(try ScrollbackExport.validatedPath(link, force: false))
    }

    func testSuggestedFileName() {
        XCTAssertEqual(ScrollbackExport.fileName(title: "zsh"), "zsh scrollback.txt")
        XCTAssertEqual(ScrollbackExport.fileName(title: "~/src/app: npm run dev"), "~-src-app- npm run dev scrollback.txt")
        XCTAssertEqual(ScrollbackExport.fileName(title: "  ..hidden\n"), "hidden scrollback.txt")
        XCTAssertEqual(ScrollbackExport.fileName(title: ""), "Terminal scrollback.txt")
        XCTAssertEqual(ScrollbackExport.fileName(title: String(repeating: "あ", count: 100)),
                       String(repeating: "あ", count: 60) + " scrollback.txt")
    }

    func testSummary() {
        XCTAssertEqual(ScrollbackExport.summary(["path": "/tmp/a.txt", "rows": 12, "bytes": 340, "lost": 0]),
                       "wrote 12 rows to /tmp/a.txt (340 bytes)")
        XCTAssertEqual(ScrollbackExport.summary(["path": "/tmp/a.txt", "rows": 12, "bytes": 340, "lost": 3]),
                       "wrote 12 rows to /tmp/a.txt (340 bytes); 3 older rows were dropped by the scrollback limit before they were read")
    }

    // MARK: - File

    func testWriterCreatesA0600FileOnlyWhenFinished() throws {
        let file = folder.appendingPathComponent("out.txt").path
        let writer = try PrivateFileWriter(path: file, force: false)
        try writer.write("héllo\n")
        try writer.write("world\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file), "not in place before finish")
        try writer.finish()
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "héllo\nworld\n")
        XCTAssertEqual(writer.bytes, 13)
        XCTAssertEqual(try permissions(file), 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["out.txt"], "no temporary file left")
    }

    func testWriterRefusesAFileThatAppearedUnlessForced() throws {
        let file = folder.appendingPathComponent("out.txt").path
        let writer = try PrivateFileWriter(path: file, force: false)
        try writer.write("new")
        FileManager.default.createFile(atPath: file, contents: Data("old".utf8), attributes: [.posixPermissions: 0o644])
        XCTAssertThrowsError(try writer.finish())
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["out.txt"])

        let forced = try PrivateFileWriter(path: file, force: true)
        try forced.write("new")
        try forced.finish()
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "new")
        XCTAssertEqual(try permissions(file), 0o600, "the replaced file's 0644 is not kept")
    }

    func testForcedWriterReplacesASymlinkInsteadOfWritingThroughIt() throws {
        let target = folder.appendingPathComponent("target.txt").path
        FileManager.default.createFile(atPath: target, contents: Data("keep".utf8))
        let link = folder.appendingPathComponent("link.txt").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        let writer = try PrivateFileWriter(path: link, force: true)
        try writer.write("export")
        try writer.finish()
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "keep")
        XCTAssertEqual(try String(contentsOfFile: link, encoding: .utf8), "export")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link))
    }

    func testCancelLeavesNothing() throws {
        let file = folder.appendingPathComponent("out.txt").path
        let writer = try PrivateFileWriter(path: file, force: false)
        try writer.write("partial")
        writer.cancel()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        XCTAssertThrowsError(try writer.finish())
    }

    // MARK: - Chunks

    func testLineBoundaryAndNormalizing() {
        XCTAssertTrue(ScrollbackExport.isLineBoundary("a\nb"))
        XCTAssertTrue(ScrollbackExport.isLineBoundary("a\n"))
        XCTAssertFalse(ScrollbackExport.isLineBoundary("ab"), "soft-wrapped")
        XCTAssertFalse(ScrollbackExport.isLineBoundary("\nb"), "first row blank")
        XCTAssertFalse(ScrollbackExport.isLineBoundary(""))
        XCTAssertEqual(ScrollbackExport.normalized("a\r\nb", ansi: false), "a\nb")
        XCTAssertEqual(ScrollbackExport.normalized("a\nb\r\n\n", ansi: false), "a\nb")
        XCTAssertEqual(ScrollbackExport.normalized("\u{1B}[31ma\r\n", ansi: true), "\u{1B}[31ma\u{1B}[0m")
        XCTAssertEqual(ScrollbackExport.normalized("\u{1B}[31ma\r\nb", ansi: true), "\u{1B}[31ma\nb\u{1B}[0m")
        XCTAssertEqual(ScrollbackExport.normalized("\u{1B}[31ma\u{1B}[0m", ansi: true), "\u{1B}[31ma\u{1B}[0m")
        XCTAssertEqual(ScrollbackExport.normalized("plain", ansi: true), "plain")
    }

    /// A terminal model: rows with a soft-wrap flag; a selection's text joins rows with "\n" unless the row wraps, and
    /// drops blank rows at its end (as Ghostty's formatter does).
    private struct FakeScreen {
        var rows: [(text: String, wraps: Bool)]
        var pruned = 0
        var reads: [ClosedRange<Int>] = []

        var scrollbar: TerminalScrollbar { TerminalScrollbar(total: rows.count, offset: max(0, rows.count - 5), rows: 5, pruned: pruned) }

        mutating func read(_ range: ClosedRange<Int>, ansi: Bool) -> String? {
            reads.append(range)
            guard range.upperBound < rows.count else { return nil }
            var selected = Array(rows[range])
            while let last = selected.last, last.text.isEmpty, selected.count > 0 { selected.removeLast() }
            var text = ""
            for (index, row) in selected.enumerated() {
                text += ansi && !row.text.isEmpty ? "\u{1B}[1m\(row.text)\u{1B}[0m" : row.text
                if index < selected.count - 1, !row.wraps { text += ansi ? "\r\n" : "\n" }
            }
            return text
        }

        /// What the whole history reads as, the export's expected content.
        func expected() -> String {
            var copy = self
            let text = copy.read(0...(rows.count - 1), ansi: false) ?? ""
            return text.isEmpty ? "" : text + "\n"
        }

        /// Prunes `count` rows from the top, as the scrollback limit does.
        mutating func prune(_ count: Int) {
            rows.removeFirst(count)
            pruned += count
        }
    }

    private func export(_ screen: inout FakeScreen, ansi: Bool = false, chunkRows: Int, searchRows: Int = 50,
                        between: ((inout FakeScreen, Int) -> Void)? = nil) throws -> (String, ScrollbackExport.Job) {
        var job = ScrollbackExport.Job(scrollbar: screen.scrollbar, ansi: ansi, chunkRows: chunkRows, searchRows: searchRows)
        var output = ""
        var steps = 0
        while !job.isDone {
            between?(&screen, steps)
            let bar = screen.scrollbar
            var copy = screen
            output += try job.step(scrollbar: bar) { copy.read($0, ansi: $1) }
            screen.reads = copy.reads
            steps += 1
            XCTAssertLessThan(steps, 10_000)
        }
        return (output, job)
    }

    func testChunksJoinToTheWholeHistory() throws {
        var rows: [(String, Bool)] = []
        for index in 0..<1000 {
            switch index % 7 {
            case 0: rows.append(("", false))  // blank lines
            case 3: rows.append(("long line \(index) part one ", true))  // soft-wrapped into the next row
            default: rows.append(("line \(index)", false))
            }
        }
        rows += [("", false), ("", false)]  // blank rows at the bottom are dropped
        for chunk in [1, 2, 3, 10, 64, 999, 1000, 5000] {
            var screen = FakeScreen(rows: rows)
            let (output, job) = try export(&screen, chunkRows: chunk)
            XCTAssertEqual(output, screen.expected(), "chunk \(chunk)")
            XCTAssertEqual(job.rows, 1002)
            XCTAssertEqual(job.lost, 0)
            XCTAssertLessThanOrEqual(screen.reads.filter { $0.count > 2 }.map(\.count).max() ?? 0, chunk + 50 + 1)
        }
    }

    func testAChunkNeverReadsTheWholeHistory() throws {
        var screen = FakeScreen(rows: (0..<10_000).map { ("row \($0)", false) })
        let (output, _) = try export(&screen, chunkRows: 500)
        XCTAssertEqual(output, screen.expected())
        let big = screen.reads.filter { $0.count > 2 }
        XCTAssertEqual(big.count, 20)
        XCTAssertTrue(big.allSatisfy { $0.count == 500 })
    }

    func testALongWrappedLineIsCutAtTheSearchLimit() throws {
        // One logical line of 300 rows: no boundary within the search; the cut adds one newline but loses nothing.
        var rows: [(String, Bool)] = (0..<300).map { ("w\($0)", $0 < 299) }
        rows.append(("after", false))
        var screen = FakeScreen(rows: rows)
        let (output, _) = try export(&screen, chunkRows: 100, searchRows: 20)
        XCTAssertEqual(output.replacingOccurrences(of: "\n", with: ""), screen.expected().replacingOccurrences(of: "\n", with: ""))
        XCTAssertTrue(output.hasSuffix("w299\nafter\n"))
    }

    func testRowsPrunedDuringTheExportAreCountedAsLost() throws {
        var screen = FakeScreen(rows: (0..<100).map { ("row \($0)", false) })
        // Before the second step, 30 rows are pruned and 30 new ones arrive (not exported: after the start).
        let (output, job) = try export(&screen, chunkRows: 10, searchRows: 0) { screen, step in
            guard step == 1 else { return }
            screen.prune(30)
            screen.rows += (100..<130).map { ("new \($0)", false) }
        }
        XCTAssertEqual(job.lost, 20)
        XCTAssertEqual(job.rowsWritten, 80)
        let lines = output.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "row 0")
        XCTAssertEqual(lines[10], "row 30")
        XCTAssertEqual(lines.last, "row 99")
        XCTAssertFalse(output.contains("new "))
    }

    func testAnsiChunksResetTheirColoursAndUseNewlines() throws {
        var screen = FakeScreen(rows: (0..<10).map { ("row \($0)", false) })
        let (output, _) = try export(&screen, ansi: true, chunkRows: 3)
        XCTAssertFalse(output.contains("\r"))
        XCTAssertTrue(output.hasPrefix("\u{1B}[1mrow 0\u{1B}[0m\n"))
        XCTAssertTrue(output.hasSuffix("row 9\u{1B}[0m\n"))
        XCTAssertEqual(output.split(separator: "\n").count, 10)
    }

    func testEmptyScreenAndUnreadableRows() throws {
        var empty = FakeScreen(rows: [("", false)])
        XCTAssertEqual(try export(&empty, chunkRows: 10).0, "")
        var job = ScrollbackExport.Job(scrollbar: TerminalScrollbar(total: 10, offset: 5, rows: 5, pruned: 0), ansi: false)
        XCTAssertThrowsError(try job.step(scrollbar: nil) { _, _ in "" })
        XCTAssertThrowsError(try job.step(scrollbar: TerminalScrollbar(total: 10, offset: 5, rows: 5, pruned: 0)) { _, _ in nil })
    }

    private func permissions(_ path: String) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
