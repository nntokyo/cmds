import Foundation
import XCTest
@testable import CmdsCore

/// The schedules on the phone (`SyncFeature.schedules`, #45 phase 3) end to end against an isolated instance
/// (docs/internals/testing.md "Sync against an isolated instance"): set `CMDS_SCHEDULES_E2E_PAIRING` to its
/// `sync-test-pairing.txt`. The test adds a schedule a few hours ahead through the instance's socket (as `cmds schedule
/// add` does; it never fires during the test), checks what a phone with the feature gets (and that its prompt, command
/// and folder never reach it), the pacing of changes, and that a phone without the feature gets nothing. It removes the
/// schedule at the end.
final class SyncSchedulesE2ETests: XCTestCase {
    private func schedules(_ phone: SyncE2EPhone, within timeout: TimeInterval = 10,
                           until condition: (ServerMessage.Schedules) -> Bool = { _ in true }) throws
        -> (ServerMessage.Schedules, Data) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .schedules(let list) = try phone.next(timeout: max(0.1, deadline.timeIntervalSinceNow)),
               condition(list) {
                return (list, phone.lastFrame)
            }
        }
        throw SyncE2EFailure("no matching schedules message")
    }

    func testSchedulesReachPhonesThatAskForThem() throws {
        let instance = try SyncE2EInstance(pairingVariable: "CMDS_SCHEDULES_E2E_PAIRING")
        let suffix = String(UUID().uuidString.prefix(8))
        let name = "e2e \(suffix)"
        let secrets = ["SECRETPROMPT\(suffix)", "SECRETCMD\(suffix)", "secretdir\(suffix)"]

        let phone = try SyncE2EPhone(instance, hello: .init(deviceName: "schedules test", deviceID: "schedules-test",
                                                            features: [SyncFeature.schedules],
                                                            pairingCode: instance.payload.code))
        XCTAssertEqual(phone.welcome.features?.contains(SyncFeature.schedules), true)
        // Sent after `welcome` and `state`, without asking.
        _ = try schedules(phone)

        let draft = ScheduleDraft(name: name, trigger: .once(at: Date().addingTimeInterval(3 * 3600).rounded()),
                                  action: .startWorkspace(StartWorkspace(cwd: "/tmp/\(secrets[2])", title: "e2e",
                                                                         command: "echo \(secrets[1])",
                                                                         prompt: secrets[0])))
        let added = try instance.api.call("schedule.add", params: ["schedule": try JSONValue.from(draft)])
        let id = try XCTUnwrap(added["schedule"]?["id"]?.stringValue)
        defer { _ = try? instance.api.call("schedule.remove", params: ["id": .string(id)]) }

        let (list, frame) = try schedules(phone) { $0.schedules.contains { $0.id == id } }
        let summary = try XCTUnwrap(list.schedules.first { $0.id == id })
        XCTAssertEqual(summary.name, name)
        XCTAssertTrue(summary.enabled)
        XCTAssertEqual(summary.action, SyncScheduleAction(type: "startWorkspace"))
        XCTAssertEqual(summary.trigger, draft.trigger)
        XCTAssertNotNil(summary.nextFireAt)
        let json = String(decoding: frame, as: UTF8.self)
        for secret in secrets { XCTAssertFalse(json.contains(secret), "\(secret) reached the phone") }

        // Changes in a burst: at most one message per second, and the last state arrives.
        var arrivals: [Date] = [Date()]
        for step in 1...3 {
            try instance.api.call("schedule.update", params: ["id": .string(id), "name": .string("\(name) \(step)")])
        }
        try instance.api.call("schedule.update", params: ["id": .string(id), "enabled": false])
        let deadline = Date().addingTimeInterval(4)
        var last: SyncScheduleSummary?
        while Date() < deadline, last?.enabled != false || last?.name != "\(name) 3" {
            if case .schedules(let list) = try phone.next(timeout: max(0.1, deadline.timeIntervalSinceNow)) {
                arrivals.append(Date())
                last = list.schedules.first { $0.id == id }
            }
        }
        XCTAssertEqual(last?.name, "\(name) 3")
        XCTAssertEqual(last?.enabled, false)
        XCTAssertNil(last?.nextFireAt, "a schedule that is off has no next run")
        for (earlier, later) in zip(arrivals.dropFirst(), arrivals.dropFirst(2)) {
            XCTAssertGreaterThan(later.timeIntervalSince(earlier), 0.8, "two schedules messages within a second")
        }

        // A phone without the feature (an older build) never gets the message, also across changes.
        let older = try SyncE2EPhone(instance, hello: .init(deviceName: "schedules old test",
                                                            deviceID: "schedules-old-test", token: phone.welcome.token))
        try instance.api.call("schedule.update", params: ["id": .string(id), "name": .string("\(name) old")])
        let until = Date().addingTimeInterval(2.5)
        while Date() < until {
            guard let message = try? older.next(timeout: max(0.1, until.timeIntervalSinceNow)) else { break }
            if case .schedules = message { XCTFail("a phone without the feature got schedules") }
        }
        _ = try schedules(phone) { $0.schedules.first { $0.id == id }?.name == "\(name) old" }

        // Removed: gone from the list.
        try instance.api.call("schedule.remove", params: ["id": .string(id)])
        _ = try schedules(phone) { !$0.schedules.contains { $0.id == id } }
    }
}

private extension Date {
    func rounded() -> Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded()) }
}
