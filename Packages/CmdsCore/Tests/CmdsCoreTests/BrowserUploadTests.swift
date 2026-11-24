import Foundation
import XCTest
@testable import CmdsCore

/// Files for a page (`browser.upload`).
final class BrowserUploadTests: XCTestCase {
    func testRequestRoundTripAndChecks() throws {
        let file = BrowserUpload.File(name: "header.png", type: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        let action = BrowserPageAction.upload(.selector("input[type=file]"), files: [file])
        let parsed = try BrowserPageAction(method: action.method, params: .object(action.params.compactMapValues { $0 }))
        XCTAssertEqual(parsed, action)

        let bad: [JSONValue] = [
            ["selector": "x"],
            ["selector": "x", "files": []],
            ["selector": "x", "files": [["name": "../etc/passwd", "data": "AA=="]]],
            ["selector": "x", "files": [["name": "a.png", "data": "not base64!"]]],
            ["selector": "x", "files": .array(Array(repeating: ["name": "a", "data": "AA=="], count: BrowserUpload.maxFiles + 1))],
        ]
        for params in bad { XCTAssertThrowsError(try BrowserPageAction(method: "browser.upload", params: params), "\(params)") }
        let typed = try BrowserUpload.files(params: ["files": [["name": "notes.pdf", "data": "AA=="]]])
        XCTAssertEqual(typed.first?.type, "application/pdf", "a missing type comes from the name")
    }

    func testReadingFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("a.txt").path
        try Data("hi".utf8).write(to: URL(fileURLWithPath: path))
        let file = try BrowserUpload.read(path: path)
        XCTAssertEqual(file.name, "a.txt")
        XCTAssertEqual(file.data, Data("hi".utf8))
        XCTAssertThrowsError(try BrowserUpload.read(path: folder.path), "a folder")
        XCTAssertThrowsError(try BrowserUpload.read(path: folder.appendingPathComponent("none").path))
    }

    func testSecretPathsAreRefused() {
        let home = "/Users/me"
        let refused = [
            "/Users/me/.ssh/config", "/Users/me/.aws/config", "/Users/me/.config/gcloud/application_default_credentials.json",
            "/Users/me/.gemini/oauth_creds.json", "/Users/me/.claude/settings.json", "/Users/me/.claude-work/.credentials.json",
            "/Users/me/Library/Keychains/login.keychain-db", "/Users/me/src/app/.env", "/Users/me/src/app/.env.production",
            "/Users/me/Downloads/aws-credentials.csv", "/Users/me/certs/server.pem", "/Users/me/certs/tls.KEY",
            "/Users/me/Desktop/id_ed25519.pub", "/Users/me/src/app/.git/config", "/tmp/x/.git/objects/ab/cd",
        ]
        for path in refused { XCTAssertNotNil(BrowserUpload.refusal(realPath: path, home: home), path) }
        let allowed = ["/Users/me/Desktop/header.png", "/Users/me/src/app/.gitignore", "/Users/me/.config/other/a.json",
                       "/Users/me/src/app/environment.md", "/Users/me/keynote.txt", "/tmp/claude/out.png"]
        for path in allowed { XCTAssertNil(BrowserUpload.refusal(realPath: path, home: home), path) }
    }

    func testSymbolicLinksAreJudgedByTheirTarget() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cmds-upload-link-\(UUID().uuidString)").resolvingSymlinksInPath()
        let home = root.appendingPathComponent("home")
        try fm.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let secret = home.appendingPathComponent(".ssh/key-copy")
        try Data("secret".utf8).write(to: secret)
        let innocent = root.appendingPathComponent("photo.png")
        try fm.createSymbolicLink(at: innocent, withDestinationURL: secret)
        XCTAssertThrowsError(try BrowserUpload.read(path: innocent.path, home: home.path), "a link named photo.png into ~/.ssh")
        XCTAssertThrowsError(try BrowserUpload.read(path: secret.path, home: home.path))
    }
}
