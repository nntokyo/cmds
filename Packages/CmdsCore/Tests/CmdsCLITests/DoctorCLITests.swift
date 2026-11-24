import XCTest
@testable import cmds_cli
@testable import CmdsCore

final class DoctorCLITests: XCTestCase {
    func testFormat() {
        let report = DoctorReport(findings: [
            DoctorFinding(id: "version", level: .ok, text: "cmds 0.33.0 (51)"),
            DoctorFinding(id: "schedules", level: .warn, text: "1 dropped", fix: "cmds schedule deleted"),
        ])
        XCTAssertEqual(Format.doctor(report), """
            ok    version    cmds 0.33.0 (51)
            warn  schedules  1 dropped  → cmds schedule deleted

            """)
        XCTAssertEqual(CLI.lookup(["doctor"])?.0.name, "doctor")
    }
}
