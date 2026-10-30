import Foundation
import XCTest
@testable import CmdsCore

final class AgentSessionTests: XCTestCase {
    let uuid = "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"

    func testResumeCommands() {
        let claude = AgentSession(agent: .claude, sessionID: uuid, cwd: "/Users/me/src/app")
        XCTAssertEqual(AgentResume.command(for: claude), "cd '/Users/me/src/app' && claude --resume \(uuid)")
        let codex = AgentSession(agent: .codex, sessionID: uuid, cwd: "~/work dir")
        XCTAssertEqual(AgentResume.command(for: codex), "cd ~/'work dir' && codex resume \(uuid)")
        let noCwd = AgentSession(agent: .codex, sessionID: uuid)
        XCTAssertEqual(AgentResume.command(for: noCwd), "codex resume \(uuid)")
        // A cwd that cannot be quoted for every shell is left out rather than typed.
        let quote = AgentSession(agent: .claude, sessionID: uuid, cwd: "/tmp/it's")
        XCTAssertEqual(AgentResume.command(for: quote), "claude --resume \(uuid)")
        XCTAssertNil(AgentResume.command(for: AgentSession(agent: .other, sessionID: uuid)))
    }

    func testRejectsUnsafeSessionIDs() {
        XCTAssertTrue(AgentResume.isValidSessionID(uuid))
        for bad in ["", "-rf", ".hidden", "a b", "x;rm -rf ~", "$(id)", "id\n", "`x`", "é", String(repeating: "a", count: 129)] {
            XCTAssertFalse(AgentResume.isValidSessionID(bad), bad)
            XCTAssertNil(AgentResume.command(for: AgentSession(agent: .claude, sessionID: bad)), bad)
        }
    }

    func testQuotedPath() {
        XCTAssertEqual(AgentResume.quotedPath("/a b/c"), "'/a b/c'")
        XCTAssertEqual(AgentResume.quotedPath("~"), "~")
        XCTAssertNil(AgentResume.quotedPath("relative/dir"))
        XCTAssertNil(AgentResume.quotedPath("/a\\b"))
        XCTAssertNil(AgentResume.quotedPath("/a\nb"))
        XCTAssertNil(AgentResume.quotedPath("/a!b"))
    }

    func testCodableRoundTripAndLenientDecoding() throws {
        let session = AgentSession(agent: .claude, sessionID: uuid, cwd: "/x", host: "home", title: "✳ Fix login",
                                   model: "Opus", lastSeen: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try JSONEncoder().encode(session)
        XCTAssertEqual(try JSONDecoder().decode(AgentSession.self, from: data), session)
        let minimal = try JSONDecoder().decode(AgentSession.self, from: Data(#"{"agent":"codex","sessionID":"\#(uuid)"}"#.utf8))
        XCTAssertEqual(minimal.agent, .codex)
        XCTAssertNil(minimal.cwd)
        XCTAssertThrowsError(try JSONDecoder().decode(AgentSession.self, from: Data(#"{"agent":"claude","sessionID":"a;b"}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(AgentSession.self, from: Data(#"{"agent":"gemini","sessionID":"abc"}"#.utf8)))
    }

    func testSummary() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = AgentSession(agent: .claude, sessionID: uuid, title: "✳ Fix login", model: "Opus 4.7",
                                   lastSeen: now.addingTimeInterval(-3 * 3600))
        XCTAssertEqual(session.summary(now: now), "Claude Code session “Fix login” (Opus 4.7, 3 h ago)")
        XCTAssertEqual(AgentSession(agent: .codex, sessionID: uuid, lastSeen: now).summary(now: now), "Codex session (just now)")
    }

    func testEmptyPrompt() {
        let screen = "Last login\n~/src % \n"
        XCTAssertTrue(AgentResume.isAtEmptyPrompt(screen: screen, cursor: (1, 8)))
        // Something typed after the prompt.
        XCTAssertFalse(AgentResume.isAtEmptyPrompt(screen: "~/src % git sta", cursor: (0, 15)))
        // A right prompt after the cursor does not matter.
        XCTAssertTrue(AgentResume.isAtEmptyPrompt(screen: "❯                 main 12:00", cursor: (0, 2)))
        // Wide characters take two cells.
        XCTAssertTrue(AgentResume.isAtEmptyPrompt(screen: "~/日本 % ", cursor: (0, 9)))
        XCTAssertFalse(AgentResume.isAtEmptyPrompt(screen: "~/日本 % x", cursor: (0, 10)))
        // Editors, password prompts, unknown cursor.
        XCTAssertFalse(AgentResume.isAtEmptyPrompt(screen: "Password: ", cursor: (0, 10)))
        XCTAssertFalse(AgentResume.isAtEmptyPrompt(screen: "~ % ", cursor: nil))
        XCTAssertFalse(AgentResume.isAtEmptyPrompt(screen: "~ % ", cursor: (3, 0)))
    }

    func testCleanTitle() {
        XCTAssertEqual(AgentResume.cleanTitle("✳ Fix login"), "Fix login")
        for noise in [nil, "", "zsh", "Terminal", "/tmp/x", "~/src", "me@host:~/src", "claude", "✳ Claude Code"] {
            XCTAssertNil(AgentResume.cleanTitle(noise), noise ?? "nil")
        }
    }

    func testLooksLikePrompt() {
        XCTAssertTrue(AgentResume.looksLikePrompt(screen: "Last login: Mon\nme@host:~/src$ "))
        XCTAssertTrue(AgentResume.looksLikePrompt(screen: "~/src main ❯\n\n"))
        XCTAssertTrue(AgentResume.looksLikePrompt(screen: "root@box:/# "))
        XCTAssertFalse(AgentResume.looksLikePrompt(screen: "me@host's password: "))
        XCTAssertFalse(AgentResume.looksLikePrompt(screen: "Enter passphrase for key '/x':"))
        XCTAssertFalse(AgentResume.looksLikePrompt(screen: "Are you sure you want to continue connecting (yes/no/[fingerprint])? "))
        XCTAssertFalse(AgentResume.looksLikePrompt(screen: "Welcome to Ubuntu"))
        XCTAssertFalse(AgentResume.looksLikePrompt(screen: ""))
    }

    func testRemotePolicyPinsResumeToOwnPane() throws {
        let scope = RemoteScope(paneID: "p7", workspaceID: "w3")
        let sessions = try RemoteAPIPolicy.authorize(method: "agent.sessions", params: nil, scope: scope)
        XCTAssertEqual(sessions?["pane"]?.stringValue, "p7")
        let resume = try RemoteAPIPolicy.authorize(method: "agent.resume", params: ["all": false], scope: scope)
        XCTAssertEqual(resume?["pane"]?.stringValue, "p7")
        XCTAssertNil(resume?["all"])
        XCTAssertThrowsError(try RemoteAPIPolicy.authorize(method: "agent.resume", params: ["all": true], scope: scope)) {
            XCTAssertEqual(($0 as? RPCError)?.code, 403)
        }
        XCTAssertThrowsError(try RemoteAPIPolicy.authorize(method: "agent.resume", params: ["pane": "p1"], scope: scope)) {
            XCTAssertEqual(($0 as? RPCError)?.code, 403)
        }
    }
}
