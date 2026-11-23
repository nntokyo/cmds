import Foundation
import XCTest
@testable import CmdsCore

/// A workspace's environment variables (#174 G23).
final class WorkspaceEnvironmentTests: XCTestCase {
    func testParse() throws {
        let environment = try WorkspaceEnvironment.parse("""
            # comment
            NODE_ENV=development

            export API_URL = http://localhost:8080/?a=b
            TOKEN=keychain:cmds.env/TOKEN
            OTHER=keychain:github.com
            EMPTY=
            NODE_ENV=test
            """)
        XCTAssertEqual(environment.entries, [
            .init(name: "API_URL", value: .plain(" http://localhost:8080/?a=b")),
            .init(name: "TOKEN", value: .keychain(service: "cmds.env", account: "TOKEN")),
            .init(name: "OTHER", value: .keychain(service: "github.com", account: nil)),
            .init(name: "EMPTY", value: .plain("")),
            .init(name: "NODE_ENV", value: .plain("test")),
        ])
        XCTAssertEqual(environment.lines, ["API_URL= http://localhost:8080/?a=b", "TOKEN=keychain:cmds.env/TOKEN",
                                           "OTHER=keychain:github.com", "EMPTY=", "NODE_ENV=test"])
        XCTAssertEqual(try WorkspaceEnvironment.parse(environment.lines.joined(separator: "\n")), environment, "round trip")
        XCTAssertEqual(environment.entries.filter(\.isSecret).map(\.name), ["TOKEN", "OTHER"])
    }

    func testInvalid() {
        for text in ["NOEQUALS", "1A=x", "A-B=x", "=x", "CMDS_SOCKET_PATH=/tmp/x", "cmds_pane_id=x", "A=keychain:",
                     "A=keychain:/acct", "A=keychain:svc/",
                     (0...WorkspaceEnvironment.maxEntries).map { "V\($0)=x" }.joined(separator: "\n"),
                     "A=" + String(repeating: "x", count: WorkspaceEnvironment.maxValueLength + 1)] {
            XCTAssertThrowsError(try WorkspaceEnvironment.parse(text), text)
        }
        XCTAssertEqual(try WorkspaceEnvironment.parse(" \n# only a comment\n"), WorkspaceEnvironment())
    }

    func testResolved() throws {
        let environment = try WorkspaceEnvironment.parse("A=1\nB=keychain:svc/b\nC=keychain:gone")
        let (variables, missing) = environment.resolved { service, account in
            service == "svc" && account == "b" ? "secret" : nil
        }
        XCTAssertEqual(variables, ["A": "1", "B": "secret"])
        XCTAssertEqual(missing, ["C"])
    }
}
