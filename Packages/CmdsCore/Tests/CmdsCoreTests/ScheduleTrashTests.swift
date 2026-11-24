import XCTest
@testable import CmdsCore

/// Recently deleted schedules (`schedules-deleted.json`, #449).
final class ScheduleTrashTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_754_000)

    private func schedule(_ id: String, name: String = "report") -> JSONValue {
        ["id": .string(id), "name": .string(name), "trigger": ["type": "weekly", "weekdays": ["mon"], "times": ["09:00"]],
         "action": ["type": "startWorkspace", "cwd": "/tmp", "command": "claude", "prompt": "write it"]]
    }

    func testDroppedElementsKeepTheirJSONAndWhy() throws {
        let text = """
            {"version": 2, "schedules": [
              {"id": "s00000001", "name": "ok", "trigger": {"type": "once", "at": 1793000000},
               "action": {"type": "startWorkspace", "cwd": "/tmp", "command": "claude"}},
              {"id": "s00000001", "name": "same id", "trigger": {"type": "once", "at": 1793000000},
               "action": {"type": "startWorkspace", "cwd": "/tmp", "command": "claude"}},
              {"id": "s00000002", "name": "no times", "trigger": {"type": "weekly", "weekdays": ["mon"], "times": []},
               "action": {"type": "startWorkspace", "cwd": "/tmp", "command": "claude"}},
              {"id": "s00000003", "name": "unknown", "trigger": {"type": "weird"},
               "action": {"type": "startWorkspace", "cwd": "/srv/bot", "prompt": "keep me"}},
              42
            ]}
            """
        let file = try JSONDecoder().decode(ScheduleFile.self, from: Data(text.utf8))
        XCTAssertEqual(file.schedules.map(\.name), ["ok"])
        XCTAssertEqual(file.dropped, 4)
        let problems = file.droppedElements.map(\.problem)
        XCTAssertEqual(problems[0], "duplicate id s00000001")
        XCTAssertFalse(problems[1].isEmpty)
        XCTAssertTrue(problems[2].hasPrefix("trigger.type"), problems[2])
        XCTAssertEqual(file.droppedElements[2].json["action"]?["prompt"]?.stringValue, "keep me")
        XCTAssertEqual(file.droppedElements[3].json, .number(42))
    }

    func testAddTrimsAndKeepsNewestFirst() {
        var trash = ScheduleTrash()
        trash.add(DeletedSchedule(schedule: schedule("s00000001"), deletedAt: now.addingTimeInterval(-31 * 86400),
                                  reason: .removed), now: now)
        XCTAssertTrue(trash.deleted.isEmpty, "older than 30 days")
        for i in 0..<(ScheduleTrash.maxEntries + 5) {
            trash.add(DeletedSchedule(schedule: schedule(String(format: "s%08x", i)), deletedAt: now.addingTimeInterval(Double(i)),
                                      reason: .removed, removedBy: .api(pane: "p1")), now: now.addingTimeInterval(200))
        }
        XCTAssertEqual(trash.deleted.count, ScheduleTrash.maxEntries)
        XCTAssertEqual(trash.deleted.first?.id, String(format: "s%08x", ScheduleTrash.maxEntries + 4))
    }

    func testTheSameDroppedElementIsKeptOnce() {
        var trash = ScheduleTrash()
        let entry = DeletedSchedule(schedule: schedule("s00000001"), deletedAt: now, reason: .dropped, problem: "x")
        trash.add(entry, now: now)
        trash.add(DeletedSchedule(schedule: schedule("s00000001"), deletedAt: now.addingTimeInterval(60), reason: .dropped,
                                  problem: "x"), now: now)
        XCTAssertEqual(trash.deleted.count, 1)
        // Removed twice (restored in between) is two entries; the newest is restored.
        trash.add(DeletedSchedule(schedule: schedule("s00000001", name: "a"), deletedAt: now.addingTimeInterval(1), reason: .removed), now: now)
        trash.add(DeletedSchedule(schedule: schedule("s00000001", name: "b"), deletedAt: now.addingTimeInterval(2), reason: .removed), now: now)
        XCTAssertEqual(trash.deleted.count, 3)
        XCTAssertEqual(trash.index(of: "s00000001").map { trash.deleted[$0].name }, "b")
        XCTAssertNil(trash.index(of: "s00000009"))
    }

    func testRoundTripAndLenientRead() throws {
        var trash = ScheduleTrash()
        trash.add(DeletedSchedule(schedule: schedule("s00000001"), deletedAt: now, reason: .removed,
                                  removedBy: .api(pane: "p12")), now: now)
        trash.add(DeletedSchedule(schedule: .number(42), deletedAt: now, reason: .dropped, problem: "cannot be read"), now: now)
        let data = try JSONEncoder().encode(trash)
        let back = try JSONDecoder().decode(ScheduleTrash.self, from: data)
        XCTAssertEqual(back, trash)
        XCTAssertEqual(back.deleted.compactMap(\.decoded).map(\.name), ["report"])

        let text = #"{"version": 1, "deleted": [{"schedule": {"id": "s00000001"}}, 7,"#
            + #" {"schedule": {"id": "s00000002"}, "deletedAt": 1793754000, "reason": "later"}]}"#
        let lenient = try JSONDecoder().decode(ScheduleTrash.self, from: Data(text.utf8))
        XCTAssertEqual(lenient.deleted.map(\.id), ["s00000002"], "no date: dropped; an unknown reason reads as removed")
        XCTAssertEqual(lenient.deleted.first?.reason, .removed)
    }
}
