import Foundation
import XCTest
@testable import CmdsCore

final class AgentSessionHistoryTests: XCTestCase {
    private func id(_ n: Int) -> String { String(format: "0199a1b2-c3d4-7e5f-8a9b-%012ld", n) }
    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }

    func testNewestFirstAndDeduplicatedByAgentSessionAndHost() {
        var history = AgentSessionHistory()
        XCTAssertTrue(history.record(AgentSession(agent: .claude, sessionID: id(1), cwd: "/a", lastSeen: at(10))))
        XCTAssertTrue(history.record(AgentSession(agent: .codex, sessionID: id(2), cwd: "/b", lastSeen: at(20))))
        // Same id under another agent or on a server: other sessions.
        history.record(AgentSession(agent: .codex, sessionID: id(1), lastSeen: at(5)))
        history.record(AgentSession(agent: .claude, sessionID: id(1), host: "home", lastSeen: at(15)))
        XCTAssertEqual(history.sessions.map(\.lastSeen), [at(20), at(15), at(10), at(5)])
        // A newer report of the first session moves it to the top instead of adding it again.
        XCTAssertTrue(history.record(AgentSession(agent: .claude, sessionID: id(1), cwd: "/elsewhere", title: "Fix login",
                                                  model: "Opus", lastSeen: at(30))))
        XCTAssertEqual(history.sessions.count, 4)
        let top = history.sessions[0]
        XCTAssertEqual(top.sessionID, id(1))
        XCTAssertNil(top.host)
        XCTAssertEqual(top.cwd, "/a", "resumes where it was first seen")
        XCTAssertEqual(top.title, "Fix login")
        XCTAssertEqual(top.model, "Opus")
        XCTAssertEqual(top.lastSeen, at(30))
    }

    func testUpdatesKeepKnownDetailsAndOlderReportsDoNotWin() {
        var history = AgentSessionHistory()
        history.record(AgentSession(agent: .claude, sessionID: id(1), title: "Fix login", model: "Opus", lastSeen: at(10),
                                    account: "work", configDir: "/Users/me/.claude-work"))
        // A newer report without a title keeps the known one; its account wins.
        history.record(AgentSession(agent: .claude, sessionID: id(1), lastSeen: at(20)))
        XCTAssertEqual(history.sessions[0].title, "Fix login")
        XCTAssertEqual(history.sessions[0].model, "Opus")
        XCTAssertNil(history.sessions[0].account)
        // An older report changes nothing.
        XCTAssertFalse(history.record(AgentSession(agent: .claude, sessionID: id(1), title: "Old", lastSeen: at(5))))
        XCTAssertEqual(history.sessions[0].title, "Fix login")
        XCTAssertEqual(history.sessions[0].lastSeen, at(20))
        // The same report again is no change (nothing to save).
        XCTAssertFalse(history.record(history.sessions[0]))
    }

    func testCapAndRecent() {
        var history = AgentSessionHistory()
        for n in 1...(AgentSessionHistory.capacity + 5) {
            history.record(AgentSession(agent: .claude, sessionID: id(n), lastSeen: at(TimeInterval(n))))
        }
        XCTAssertEqual(history.sessions.count, AgentSessionHistory.capacity)
        XCTAssertEqual(history.sessions.first?.sessionID, id(AgentSessionHistory.capacity + 5))
        XCTAssertEqual(history.sessions.last?.sessionID, id(6), "the oldest are dropped")
        XCTAssertEqual(history.recent().map(\.sessionID), (21...25).reversed().map(id))
        XCTAssertEqual(history.recent(2).count, 2)
        // Older than every kept entry of a full list: not kept.
        XCTAssertFalse(history.record(AgentSession(agent: .claude, sessionID: id(99), lastSeen: at(0))))
        XCTAssertFalse(history.sessions.contains { $0.sessionID == id(99) })
        history.removeAll()
        XCTAssertTrue(history.sessions.isEmpty)
    }

    func testRefusesSessionsThatCannotBeResumed() {
        var history = AgentSessionHistory()
        XCTAssertFalse(history.record(AgentSession(agent: .other, sessionID: id(1))))
        XCTAssertFalse(history.record(AgentSession(agent: .claude, sessionID: "$(id)")))
        XCTAssertTrue(history.sessions.isEmpty)
    }

    func testFileRoundTripAndLenientDecoding() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = AgentSessionHistoryStore.url(supportDirectory: directory)
        XCTAssertEqual(url.lastPathComponent, "agent-history.json")
        XCTAssertTrue(AgentSessionHistoryStore.load(from: url).history.sessions.isEmpty)

        var history = AgentSessionHistory()
        history.record(AgentSession(agent: .claude, sessionID: id(1), cwd: "/a", title: "Fix login", model: "Opus",
                                    lastSeen: at(10), account: "work", configDir: "/Users/me/.claude-work"))
        history.record(AgentSession(agent: .codex, sessionID: id(2), cwd: "/srv/app", host: "home", lastSeen: at(20)))
        try AgentSessionHistoryStore.save(history, to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let loaded = AgentSessionHistoryStore.load(from: url)
        XCTAssertNil(loaded.error)
        XCTAssertEqual(loaded.history, history)

        // Bad entries are dropped, the rest re-sorted, deduplicated and kept.
        let json = """
            {"version": 1, "sessions": [
              {"agent": "claude", "sessionID": "\(id(1))", "lastSeen": 1800000010},
              {"agent": "claude", "sessionID": "$(rm -rf ~)", "lastSeen": 1800000099},
              {"agent": "antigravity", "sessionID": "\(id(3))", "lastSeen": 1800000050},
              {"agent": "codex", "sessionID": "\(id(2))", "lastSeen": 1800000030},
              {"agent": "claude", "sessionID": "\(id(1))", "lastSeen": 1800000005, "title": "Older"}
            ]}
            """
        let decoded = try JSONDecoder().decode(AgentSessionHistory.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.sessions.map(\.sessionID), [id(2), id(1)])
        XCTAssertEqual(decoded.sessions[1].title, "Older", "a missing title is filled in from the older entry")

        // A damaged file is moved aside, not overwritten.
        try Data("not json".utf8).write(to: url)
        let damaged = AgentSessionHistoryStore.load(from: url)
        XCTAssertNotNil(damaged.error)
        XCTAssertNotNil(damaged.movedAside)
        XCTAssertFalse(damaged.saveBlocked)
        XCTAssertTrue(damaged.history.sessions.isEmpty)
    }
}
