import Foundation
import XCTest
@testable import CmdsCore

/// What a resumed session is told (#440): continue, and create its scheduled jobs again.
final class ResumeNoteTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_500_000)
    private func at(_ secondsAgo: TimeInterval) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.string(from: now.addingTimeInterval(-secondsAgo))
    }
    private func use(_ id: String, _ name: String, _ input: String, ago: TimeInterval = 3600) -> Substring {
        Substring(#"{"type":"assistant","timestamp":"\#(at(ago))","message":{"content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}]}}"#)
    }
    private func result(_ id: String, _ text: String, ago: TimeInterval = 3600) -> Substring {
        Substring(#"{"type":"user","timestamp":"\#(at(ago))","message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"\#(text)"}]}}"#)
    }

    func testActiveJobs() {
        let lines = [
            use("t1", "CronCreate", #"{"cron":"3-58/5 * * * *","prompt":"run PROCESS.md"}"#),
            result("t1", "Scheduled recurring job 89b1ef41 (3-58/5 * * * *). Session-only (not written to disk, dies when Claude exits)."),
            use("t2", "CronCreate", #"{"cron":"0 9 * * *","prompt":"daily report"}"#),
            result("t2", "Scheduled recurring job e2374620 (0 9 * * *). Session-only (not written to disk)."),
            use("t3", "CronDelete", #"{"id":"e2374620"}"#),
            use("t4", "CronCreate", #"{"cron":"0 * * * *","prompt":"old","recurring":true}"#, ago: 8 * 86400),
            result("t4", "Scheduled recurring job aaaa1111 (0 * * * *). Session-only.", ago: 8 * 86400),
            use("t5", "CronCreate", #"{"cron":"*/10 * * * *","prompt":"kept on disk","durable":true}"#),
            result("t5", "Scheduled recurring job bbbb2222 (*/10 * * * *). Written to disk."),
            use("t6", "ScheduleWakeup", #"{"delaySeconds":600,"prompt":"<<autonomous-loop-dynamic>>"}"#, ago: 300),
        ]
        let jobs = ResumeNote.jobs(transcriptLines: lines, now: now)
        XCTAssertEqual(jobs, [ResumeNote.Job(kind: .cron("3-58/5 * * * *"), prompt: "run PROCESS.md"),
                              ResumeNote.Job(kind: .loop, prompt: "<<autonomous-loop-dynamic>>")],
                       "cancelled, expired and durable jobs are left out")
        let again = lines + [use("t8", "CronCreate", #"{"cron":"3-58/5 * * * *","prompt":"run PROCESS.md"}"#, ago: 600),
                             result("t8", "Scheduled recurring job 99cc8800 (3-58/5 * * * *). Session-only.", ago: 600)]
        XCTAssertEqual(ResumeNote.jobs(transcriptLines: again, now: now).filter { $0.kind != .loop }.count, 1,
                       "made again after an earlier restart: once")
        let stopped = lines + [use("t7", "ScheduleWakeup", #"{"stop":true}"#, ago: 60)]
        XCTAssertFalse(ResumeNote.jobs(transcriptLines: stopped, now: now).contains { $0.kind == .loop }, "the loop was stopped")
    }

    func testPrompts() throws {
        XCTAssertNil(ResumeNote.prompt(reason: .restart, cutOff: false, jobs: []), "an idle session: nothing to say")
        let restart = try XCTUnwrap(ResumeNote.prompt(reason: .restart, cutOff: true, jobs: []))
        XCTAssertEqual(restart, "cmds was restarted while you were working. Continue where you left off.")
        let jobs = [ResumeNote.Job(kind: .cron("3-58/5 * * * *"), prompt: "run\nPROCESS.md"), ResumeNote.Job(kind: .loop, prompt: "")]
        let withJobs = try XCTUnwrap(ResumeNote.prompt(reason: .accountSwitch(from: "info", to: "ryo"), cutOff: false, jobs: jobs))
        XCTAssertTrue(withJobs.hasPrefix("cmds moved this session to the Claude account “ryo” because “info” hit its limit."), withJobs)
        XCTAssertTrue(withJobs.contains("`3-58/5 * * * *`: “run PROCESS.md”"), withJobs)
        XCTAssertTrue(withJobs.contains("ScheduleWakeup"))
        XCTAssertTrue(withJobs.contains("cmds schedule add --name NAME --every 5m --send PROMPT --to agent"), withJobs)
        XCTAssertFalse(withJobs.contains("\n"), "one line")
        XCTAssertNotNil(ResumeNote.prompt(reason: .restart, cutOff: false, jobs: jobs), "idle, but its jobs are gone")
    }

    /// Against a real transcript when one is named (CMDS_TRANSCRIPT), read only; skipped otherwise.
    func testRealTranscript() throws {
        guard let path = ProcessInfo.processInfo.environment["CMDS_TRANSCRIPT"] else { throw XCTSkip("set CMDS_TRANSCRIPT") }
        let started = Date()
        let lines = ResumeNote.jobLines(path: path)
        let jobs = ResumeNote.jobs(transcriptLines: lines, now: Date())
        print("REAL: \(lines.count) lines in \(Date().timeIntervalSince(started)) s; jobs: \(jobs)")
    }
}
