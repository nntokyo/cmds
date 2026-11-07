import XCTest
@testable import cmds_cli
@testable import CmdsCore

/// `cmds files compare` / `cmds files sync` output, and sync jobs in `cmds transfers`.
final class FolderCompareCLITests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func info(direction: FolderSync.Direction, deleteExtra: Bool = false, truncated: Bool = false) -> FolderCompareInfo {
        let file = { (size: Int64, offset: TimeInterval) in FileItem(name: "x", kind: .file, size: size, modified: self.date + offset) }
        let entries = [
            FolderSync.Entry(leftPath: "a.txt", rightPath: "a.txt", left: file(1, 0), right: nil, status: .leftOnly),
            FolderSync.Entry(leftPath: "docs", rightPath: "docs", left: nil, right: FileItem(name: "docs", kind: .folder),
                             status: .rightOnly),
            FolderSync.Entry(leftPath: "c.txt", rightPath: "c.txt", left: file(1, 0), right: file(2, 60), status: .modified),
            FolderSync.Entry(leftPath: "d.txt", rightPath: "d.txt", left: file(1, 0), right: file(2, 0), status: .modified),
            FolderSync.Entry(leftPath: "link", rightPath: "link", left: FileItem(name: "link", kind: .symlink), right: nil,
                             status: .skipped),
            FolderSync.Entry(leftPath: "same.txt", rightPath: "same.txt", left: file(1, 0), right: file(1, 0), status: .same),
        ]
        let options = FolderSync.Options(direction: direction, deleteExtra: deleteExtra)
        return FolderCompareInfo(left: .local("/Users/me/site"), right: .remote(host: "home", path: "/srv/site"),
                                 comparison: .init(entries: entries, truncated: truncated, itemsRead: 6),
                                 decisions: FolderSync.plan(entries, options: options), options: options)
    }

    func testTwoWayPlan() {
        XCTAssertEqual(Format.folderCompare(info(direction: .both)), """
            left   /Users/me/site
            right  home:/srv/site
            →  left only      a.txt
            ←  right only     docs/
            ←  right newer    c.txt
            ?  modified       d.txt
               link (skipped) link
            plan (both): 1 → right, 2 ← left, 0 to the Trash, 1 conflicts unsettled
            """)
    }

    func testOneWayWithDeleteAndTruncation() {
        let text = Format.folderCompare(info(direction: .leftToRight, deleteExtra: true, truncated: true))
        XCTAssertTrue(text.contains("✕R right only     docs/"), text)
        XCTAssertTrue(text.contains("→  modified       d.txt"), text)
        XCTAssertTrue(text.hasSuffix("plan (leftToRight): 3 → right, 0 ← left, 1 to the Trash\n"
            + "too many items: the comparison stopped after 6; it cannot be synced"), text)
    }

    func testInfoRoundTripsAndLeavesOutSameItems() throws {
        let original = info(direction: .both)
        XCTAssertFalse(original.entries.contains { $0.status == .same })
        XCTAssertEqual(original.entries.first { $0.path == "c.txt" }?.right?.modified, 1_700_000_060)
        let decoded = try JSONDecoder().decode(FolderCompareInfo.self, from: try JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testSyncJobInTransfers() {
        let snapshot = TransferJob.Snapshot(
            id: 4, mode: .sync, sources: [.local("/a")], destination: .remote(host: "home", path: "/srv"), state: .done,
            progress: TransferJob.Progress(), log: [
                .init(path: "x", outcome: .copied, date: date, side: .right),
                .init(path: "y", outcome: .trashed, date: date, side: .right),
            ], error: nil, started: nil, finished: nil, asking: nil, syncDirection: .both)
        XCTAssertEqual(Format.transfer(TransferInfo(snapshot)), "4  done  sync  /a ↔ home:/srv  1 copied, 1 moved to the Trash")
    }
}
