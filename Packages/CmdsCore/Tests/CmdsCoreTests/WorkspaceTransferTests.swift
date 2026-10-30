import Foundation
import XCTest
@testable import CmdsCore

final class WorkspaceTransferTests: XCTestCase {
    let uuid = "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"

    private func sample() -> WorkspaceBundle {
        let claude = AgentSession(agent: .claude, sessionID: uuid, cwd: "/Users/me/app", title: "Fix login", model: "Opus",
                                  lastSeen: Date(timeIntervalSince1970: 1_800_000_000))
        let codex = AgentSession(agent: .codex, sessionID: "abc-123", cwd: "~/srv", host: "home", lastSeen: Date(timeIntervalSince1970: 1_800_000_100))
        let layout = WorkspaceBundle.Node.split(
            axis: .horizontal, ratio: 0.6,
            first: .pane(.terminal(cwd: "/Users/me/app", session: claude)),
            second: .split(axis: .vertical, ratio: 0.5,
                           first: .pane(.ssh(host: "home", remoteCwd: "~/srv", session: codex)),
                           second: .pane(WorkspaceBundle.Pane(kind: .browser, url: "http://localhost:3000"))))
        return WorkspaceBundle(workspaces: [
            .init(title: "App", workingDirectory: "/Users/me/app", focusedPaneIndex: 1, layout: layout),
            .init(layout: .pane(WorkspaceBundle.Pane(kind: .preview, path: "/tmp/a.diff", format: "diff"))),
        ], selectedIndex: 1, source: .init(version: "1.0", build: "5"))
    }

    func testRoundTrip() throws {
        let bundle = sample()
        let data = try JSONEncoder().encode(bundle)
        let decoded = try WorkspaceBundle.read(data)
        XCTAssertEqual(decoded.workspaces, bundle.workspaces)
        XCTAssertEqual(decoded.selectedIndex, 1)
        XCTAssertEqual(decoded.paneCount, 4)
        XCTAssertEqual(decoded.agentSessionCount, 2)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"format\":\"cmds.workspaces\""))
        XCTAssertTrue(json.contains("\"split\""))
        // Also through JSONValue (the socket path).
        XCTAssertEqual(try WorkspaceBundle.read(try JSONValue.from(bundle)).workspaces, bundle.workspaces)
    }

    func testRejectsWrongFormatAndNewerVersion() {
        XCTAssertThrowsError(try WorkspaceBundle.read(Data(#"{"format":"other","version":1,"workspaces":[]}"#.utf8))) {
            XCTAssertTrue("\($0)".contains("not a cmds workspace bundle"))
        }
        XCTAssertThrowsError(try WorkspaceBundle.read(Data(#"{"format":"cmds.workspaces","version":99,"workspaces":[]}"#.utf8))) {
            XCTAssertTrue("\($0)".contains("newer cmds"))
        }
        XCTAssertThrowsError(try WorkspaceBundle.read(Data("[]".utf8)))
        XCTAssertThrowsError(try WorkspaceBundle.read(Data()))
        XCTAssertThrowsError(try WorkspaceBundle.read(Data(count: WorkspaceBundle.maxBytes + 1))) {
            XCTAssertTrue("\($0)".contains("too large"))
        }
    }

    private func rejects(_ pane: WorkspaceBundle.Pane, file: StaticString = #filePath, line: UInt = #line) {
        let bundle = WorkspaceBundle(workspaces: [.init(layout: .pane(pane))])
        XCTAssertThrowsError(try bundle.validated(), file: file, line: line)
    }

    func testRejectsBadPanes() {
        rejects(.terminal(cwd: "relative/dir"))
        rejects(.terminal(cwd: "/tmp/a\nb"))
        rejects(.ssh(host: "-oProxyCommand=x", remoteCwd: nil))
        rejects(.ssh(host: "home", remoteCwd: "/tmp/'x"))
        rejects(WorkspaceBundle.Pane(kind: .browser, url: "javascript:alert(1)"))
        rejects(WorkspaceBundle.Pane(kind: .browser, cwd: "/tmp"))
        rejects(WorkspaceBundle.Pane(kind: .preview, path: "rel.md"))
        rejects(WorkspaceBundle.Pane(kind: .preview, path: "/a.md", format: "exe"))
        // Sessions only on terminal panes, for the pane's own host.
        let session = AgentSession(agent: .claude, sessionID: uuid)
        rejects(WorkspaceBundle.Pane(kind: .browser, agentSession: session))
        rejects(.ssh(host: "home", remoteCwd: nil, session: session))
        rejects(.terminal(cwd: "/tmp", session: AgentSession(agent: .claude, sessionID: uuid, host: "home")))
        rejects(.terminal(cwd: "/tmp", session: AgentSession(agent: .claude, sessionID: uuid, cwd: "x\u{1b}")))
    }

    func testRejectsBadSessionIDOnDecode() throws {
        var bundle = try JSONValue.from(sample())
        let text = String(data: try JSONEncoder().encode(bundle), encoding: .utf8)!
            .replacingOccurrences(of: uuid, with: "x;rm -rf ~")
        bundle = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        XCTAssertThrowsError(try WorkspaceBundle.read(bundle)) { XCTAssertTrue("\($0)".contains("invalid session id"), "\($0)") }
    }

    func testRejectsIndexesAndLimits() {
        let pane = WorkspaceBundle.Node.pane(.terminal(cwd: "/tmp"))
        XCTAssertThrowsError(try WorkspaceBundle(workspaces: [.init(layout: pane)], selectedIndex: 3).validated())
        XCTAssertThrowsError(try WorkspaceBundle(workspaces: [.init(focusedPaneIndex: 1, layout: pane)]).validated())
        XCTAssertThrowsError(try WorkspaceBundle(workspaces: Array(repeating: .init(layout: pane), count: 101)).validated())
        var deep = pane
        for _ in 0..<30 { deep = .split(axis: .vertical, ratio: 0.5, first: deep, second: pane) }
        XCTAssertThrowsError(try WorkspaceBundle(workspaces: [.init(layout: deep)]).validated())
        // Deep JSON is refused while decoding.
        let data = try! JSONEncoder().encode(WorkspaceBundle(workspaces: [.init(layout: deep)]))
        XCTAssertThrowsError(try WorkspaceBundle.read(data)) { XCTAssertTrue("\($0)".contains("too deeply"), "\($0)") }
    }

    func testClampsAndCleans() throws {
        let bundle = WorkspaceBundle(workspaces: [.init(title: " a\u{7}b ", layout: .split(
            axis: .horizontal, ratio: 5, first: .pane(.terminal(cwd: "/tmp")), second: .pane(WorkspaceBundle.Pane(kind: .browser, url: "about:blank"))))])
        let checked = try bundle.validated()
        XCTAssertEqual(checked.workspaces[0].title, "ab")
        guard case .split(_, let ratio, _, .pane(let browser)) = checked.workspaces[0].layout else { return XCTFail() }
        XCTAssertEqual(ratio, 0.92)
        XCTAssertNil(browser.url)
    }

    func testLegacyExport() throws {
        let workspaces: JSONValue = try JSONDecoder().decode(JSONValue.self, from: Data("""
        [{"id":"w1","title":"app","selected":false,"workingDirectory":"/Users/me/app","ports":[],"attention":false,
          "layout":{"split":{"axis":"horizontal","ratio":0.5,"first":{"pane":{"id":"p1"}},"second":{"pane":{"id":"p2"}}}},
          "panes":[{"id":"p1","kind":"terminal","title":"✳ Fix login","focused":false,"attention":false,"workingDirectory":"/Users/me/app",
                    "agent":{"agent":"claude","sessionID":"\(uuid)","model":"Opus","limits":[],"updatedAt":1800000000}},
                   {"id":"p2","kind":"terminal","title":"ssh home","focused":true,"attention":false,"workingDirectory":"~/srv",
                    "remote":{"host":"home","connected":true}}]},
         {"id":"w2","title":"Notes","selected":true,"workingDirectory":"/tmp","panes":[
           {"id":"p3","kind":"browser","title":"x","focused":true,"attention":false,"url":"https://example.com"},
           {"id":"p4","kind":"preview","title":"y","focused":false,"attention":false,"file":"/tmp/n.md"},
           {"id":"p5","kind":"terminal","title":"z","focused":false,"attention":false,"workingDirectory":"bad relative"}]}]
        """.utf8))
        let agents: JSONValue = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"panes":[{"workspace":"w1","pane":"p2","usage":{"agent":"codex","sessionID":"sess-2","limits":[],"updatedAt":1800000100}}],"limits":[]}
        """.utf8))
        let bundle = try WorkspaceBundle.legacy(workspaces: workspaces, agents: agents, sessions: nil, home: "/Users/me")
        XCTAssertEqual(bundle.source?.legacy, true)
        XCTAssertEqual(bundle.selectedIndex, 1)
        XCTAssertEqual(bundle.workspaces.count, 2)
        let first = bundle.workspaces[0]
        XCTAssertNil(first.title, "derived from the directory")
        XCTAssertEqual(first.focusedPaneIndex, 1)
        XCTAssertEqual(first.panes[0].agentSession?.sessionID, uuid)
        XCTAssertEqual(first.panes[0].agentSession?.title, "Fix login")
        XCTAssertEqual(first.panes[0].agentSession?.cwd, "/Users/me/app")
        XCTAssertEqual(first.panes[1].host, "home")
        XCTAssertEqual(first.panes[1].agentSession?.agent, .codex)
        XCTAssertEqual(first.panes[1].agentSession?.host, "home")
        XCTAssertEqual(first.panes[1].agentSession?.cwd, "~/srv")
        let second = bundle.workspaces[1]
        XCTAssertEqual(second.title, "Notes")
        XCTAssertEqual(second.panes.map(\.kind), [.browser, .preview, .terminal])
        XCTAssertNil(second.panes[2].cwd, "invalid cwd dropped")
        // agent.sessions wins over live usage (remembered sessions of exited agents too).
        let sessions: JSONValue = try .from(AgentSessionList(mode: .ask, sessions: [
            AgentSessionEntry(workspace: "w2", pane: "p5", state: .offered,
                              session: AgentSession(agent: .claude, sessionID: "old-1", cwd: "/tmp"), command: nil),
        ]))
        let withSessions = try WorkspaceBundle.legacy(workspaces: workspaces, agents: agents, sessions: sessions, home: "/Users/me")
        XCTAssertEqual(withSessions.workspaces[1].panes[2].agentSession?.sessionID, "old-1")
        XCTAssertEqual(withSessions.agentSessionCount, 3)
    }
}
