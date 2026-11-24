import XCTest
@testable import CmdsCore

final class DoctorTests: XCTestCase {
    private func snapshot() -> DoctorSnapshot {
        DoctorSnapshot(runningVersion: "0.33.0", runningBuild: "51", diskVersion: "0.33.0", diskBuild: "51",
                       resumeMode: "always", loginItem: LoginItemState(status: .on))
    }

    private func finding(_ id: String, _ s: DoctorSnapshot) -> DoctorFinding? {
        Doctor.report(s).findings.first { $0.id == id }
    }

    func testAllWell() {
        let report = Doctor.report(snapshot())
        XCTAssertEqual(report.level, .ok)
        XCTAssertEqual(report.findings.map(\.id), ["version", "resume", "login", "schedules", "hangs", "memory"])
    }

    func testVersion() {
        var s = snapshot()
        s.diskVersion = "0.34.0"
        s.diskBuild = "52"
        XCTAssertEqual(finding("update", s)?.text, "cmds 0.33.0 (51) runs; 0.34.0 (52) is installed")
        s.updateOnQuit = "0.35.0"
        XCTAssertEqual(finding("update", s)?.level, .note)
        XCTAssertTrue(finding("update", s)?.text.contains("0.35.0 is downloaded") ?? false)
        s = snapshot()
        s.diskBuild = nil
        XCTAssertEqual(finding("version", s)?.level, .warn)
        s = snapshot()
        s.diskBuild = "50"
        XCTAssertEqual(finding("version", s)?.level, .ok, "an older copy on disk is not an update")
    }

    func testRestartSettings() {
        var s = snapshot()
        s.resumeMode = "ask"
        s.loginItem = LoginItemState(status: .off)
        XCTAssertEqual(finding("resume", s)?.level, .note)
        XCTAssertEqual(finding("login", s)?.fix, "cmds launch-at-login on")
        s.loginItem = LoginItemState(status: .needsApproval)
        XCTAssertEqual(finding("login", s)?.level, .warn)
    }

    func testSchedules() {
        var s = snapshot()
        s.schedulesDropped = 2
        s.scheduleProblems = ["report: account work was removed"]
        let found = finding("schedules", s)
        XCTAssertEqual(found?.level, .warn)
        XCTAssertEqual(found?.text, "cannot run as they are: report: account work was removed; 2 dropped from schedules.json in the last 7 days")
        XCTAssertEqual(found?.fix, "cmds schedule, cmds schedule deleted")
        s = snapshot()
        s.schedulesReadOnly = "the file was made by a newer cmds"
        XCTAssertTrue(finding("schedules", s)?.text.hasPrefix("schedules are read only") ?? false)
    }

    func testHangsMemoryBluetooth() {
        var s = snapshot()
        s.recentHangs = ["hang-2.txt", "hang-1.txt"]
        s.memoryPressure = .critical
        s.bluetoothStatus = "Failed: No resources available for L2CAP. Trying again in 300 s."
        s.bluetoothFailures = 2
        XCTAssertEqual(finding("hangs", s)?.text, "2 hangs in the last 24 h (newest: hangs/hang-2.txt)")
        XCTAssertEqual(finding("memory", s)?.level, .warn)
        XCTAssertEqual(finding("bluetooth", s)?.level, .ok)
        s.bluetoothFailures = 3
        XCTAssertEqual(finding("bluetooth", s)?.level, .warn)
        XCTAssertEqual(Doctor.report(s).level, .warn)
    }

    func testCodable() throws {
        let report = Doctor.report(snapshot())
        XCTAssertEqual(try JSONDecoder().decode(DoctorReport.self, from: JSONEncoder().encode(report)), report)
        let lenient = try JSONDecoder().decode(DoctorFinding.self, from: Data(#"{"id": "x", "level": "later", "text": "t"}"#.utf8))
        XCTAssertEqual(lenient.level, .note)
    }

    func testSessionJobs() {
        var s = snapshot()
        s.sessionJobs = ["p3": 0]
        XCTAssertNil(finding("session-jobs", s), "nothing to move: no line")
        s.sessionJobs = ["p12": 2, "p3": 1]
        let found = finding("session-jobs", s)
        XCTAssertEqual(found?.level, .note)
        XCTAssertEqual(found?.text, "3 CronCreate jobs end with their session, not moved to schedules: p3 (1), p12 (2)")
        XCTAssertEqual(found?.fix, "cmds schedule from-session --pane P --apply for each")
        s.sessionJobs = ["p3": 1]
        XCTAssertEqual(finding("session-jobs", s)?.fix, "cmds schedule from-session --pane p3 --apply")
        XCTAssertEqual(finding("session-jobs", s)?.text, "1 CronCreate job ends with its session, not moved to schedules: p3 (1)")
        XCTAssertEqual(Doctor.report(s).level, .note, "a note, not a warning (doctor exits 0)")
    }
}
