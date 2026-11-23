import Foundation
import XCTest
@testable import CmdsCore

/// `.cmds.json` project files (#174 G20).
final class ProjectFileTests: XCTestCase {
    private func parse(_ json: String) throws -> ProjectFile { try ProjectFile.parse(Data(json.utf8)) }

    func testParse() throws {
        let file = try parse("""
            {"commands": [{"title": "Dev server", "run": "npm run dev"},
                          {"run": "npm test -- --watch", "split": "down"}],
             "open": ["http://localhost:5173"]}
            """)
        XCTAssertEqual(file.commands, [ProjectFile.Command(title: "Dev server", run: "npm run dev", split: .right),
                                       ProjectFile.Command(title: "npm test -- --watch", run: "npm test -- --watch", split: .down)])
        XCTAssertEqual(file.pages, ["http://localhost:5173"])
        XCTAssertEqual(file.lines, ["Dev server: npm run dev  [right]", "npm test -- --watch: npm test -- --watch  [down]",
                                    "open http://localhost:5173"])
        XCTAssertEqual(file.digest.count, 64)
    }

    func testDigestFollowsTheBytes() throws {
        let one = try parse(#"{"commands": [{"run": "make"}]}"#)
        let same = try parse(#"{"commands": [{"run": "make"}]}"#)
        let changed = try parse(#"{"commands": [{"run": "make all"}]}"#)
        XCTAssertEqual(one.digest, same.digest)
        XCTAssertNotEqual(one.digest, changed.digest, "a changed file is asked about again")
    }

    func testInvalidFiles() {
        let bad = [
            "[]", "not json", #"{}"#, #"{"commands": []}"#,
            #"{"commands": [{"title": "x"}]}"#,
            #"{"commands": [{"run": "a\nb"}]}"#,
            #"{"commands": [{"run": "x", "split": "left"}]}"#,
            #"{"open": ["file:///etc/passwd"]}"#,
            #"{"open": ["javascript:alert(1)"]}"#,
            #"{"commands": [{"run": "x"}], "env": {"A": "1"}}"#,
            "{\"commands\": [" + Array(repeating: #"{"run": "x"}"#, count: 9).joined(separator: ",") + "]}",
        ]
        for json in bad {
            XCTAssertThrowsError(try parse(json), json)
        }
        XCTAssertThrowsError(try ProjectFile.parse(Data(count: ProjectFile.maxBytes + 1)))
    }

    func testFindStopsAtTheRepository() {
        let files: Set<String> = ["/r/.git", "/r/.cmds.json", "/other/.cmds.json"]
        let exists = { files.contains($0) }
        XCTAssertEqual(ProjectFile.find(from: "/r/src/app", fileExists: exists), "/r/.cmds.json")
        XCTAssertEqual(ProjectFile.find(from: "/r", fileExists: exists), "/r/.cmds.json")
        XCTAssertNil(ProjectFile.find(from: "/r2/src", fileExists: { $0 == "/r2/src/.git" || $0 == "/.cmds.json" }),
                     "not above the repository's top level")
        XCTAssertEqual(ProjectFile.find(from: "/other", fileExists: exists), "/other/.cmds.json")
    }
}
