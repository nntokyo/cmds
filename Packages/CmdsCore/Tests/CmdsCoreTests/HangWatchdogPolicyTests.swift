import Foundation
import XCTest
@testable import CmdsCore

/// When a hung main thread is sampled.
final class HangWatchdogPolicyTests: XCTestCase {
    func testOneSamplePerHangAndNotTooOften() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(HangWatchdogPolicy.shouldRecord(blockedFor: 29, recordedThisHang: false, lastRecordAt: nil, now: now))
        XCTAssertTrue(HangWatchdogPolicy.shouldRecord(blockedFor: 30, recordedThisHang: false, lastRecordAt: nil, now: now))
        XCTAssertFalse(HangWatchdogPolicy.shouldRecord(blockedFor: 600, recordedThisHang: true, lastRecordAt: nil, now: now))
        XCTAssertFalse(HangWatchdogPolicy.shouldRecord(blockedFor: 40, recordedThisHang: false,
                                                       lastRecordAt: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(HangWatchdogPolicy.shouldRecord(blockedFor: 40, recordedThisHang: false,
                                                      lastRecordAt: now.addingTimeInterval(-601), now: now))
    }

    func testFilesAndLog() {
        let date = Date(timeIntervalSince1970: 1_794_000_000)
        XCTAssertEqual(HangWatchdogPolicy.fileName(at: date, timeZone: TimeZone(identifier: "Asia/Tokyo")!), "hang-20261107-062000.txt")
        let names = (1...7).map { "hang-2026111\($0)-000000.txt" } + ["hangs.log", "notes.txt"]
        XCTAssertEqual(HangWatchdogPolicy.filesToDelete(names), ["hang-20261111-000000.txt", "hang-20261112-000000.txt"])
        XCTAssertTrue(HangWatchdogPolicy.logLine(startedAt: date, duration: 9000.4, file: nil).hasSuffix("\t9000 s\t-\n"))
        XCTAssertTrue(HangWatchdogPolicy.logLine(startedAt: date, duration: nil, file: "hang-x.txt").hasSuffix("\tnot over\thang-x.txt\n"))
    }
}
