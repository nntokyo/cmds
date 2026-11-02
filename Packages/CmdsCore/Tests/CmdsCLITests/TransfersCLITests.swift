import XCTest
@testable import cmds_cli
@testable import CmdsCore

/// `cmds transfers`: one line per job, then its error and failed items.
final class TransfersCLITests: XCTestCase {
    private func info(state: TransferJob.State, sources: [FileLocation], log: [TransferJob.Outcome],
                      bytes: (Int64, Int64) = (0, 0), error: String? = nil, asking: String? = nil) -> TransferInfo {
        let date = Date(timeIntervalSince1970: 0)
        return TransferInfo(TransferJob.Snapshot(
            id: 3, mode: .copy, sources: sources, destination: .remote(host: "home", path: "/srv"), state: state,
            progress: TransferJob.Progress(bytesDone: bytes.0, bytesTotal: bytes.1, current: "a.txt"),
            log: log.enumerated().map { TransferJob.LogEntry(path: "p\($0.offset)", outcome: $0.element, date: date) },
            error: error, started: nil, finished: nil, asking: asking))
    }

    func testRunningJob() {
        let job = info(state: .running, sources: [.local("/a"), .local("/b")], log: [.copied, .moved, .skipped],
                       bytes: (1_000_000, 4_000_000))
        XCTAssertEqual(Format.transfer(job), "3  running  copy  2 items → home:/srv  1 MB of 4 MB  (a.txt)  "
            + "1 copied, 1 moved, 1 skipped")
    }

    func testFailedJobListsItsErrorAndFailures() {
        let job = info(state: .failed, sources: [.local("/a")], log: [.failed("bad\nline"), .originalKept("kept")],
                       error: "gone", asking: "x")
        XCTAssertEqual(Format.transfer(job), "3  failed  copy  /a → home:/srv  asking about x  2 failed\n"
            + "    error: gone\n    p0: bad line\n    p1: kept")
    }
}
