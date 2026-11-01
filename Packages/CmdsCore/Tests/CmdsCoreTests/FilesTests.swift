import Foundation
import XCTest
@testable import CmdsCore

final class FileSortingTests: XCTestCase {
    private let entries = [
        FileEntry(name: "file10.txt", isFolder: false, size: 300, modified: Date(timeIntervalSince1970: 30), kind: "Text"),
        FileEntry(name: "File2.txt", isFolder: false, size: 100, modified: Date(timeIntervalSince1970: 10), kind: "Text"),
        FileEntry(name: "src", isFolder: true, modified: Date(timeIntervalSince1970: 5), kind: "Folder"),
        FileEntry(name: ".hidden", isFolder: false, isHidden: true, size: 5, modified: Date(timeIntervalSince1970: 50), kind: "Document"),
        FileEntry(name: "Docs", isFolder: true, modified: Date(timeIntervalSince1970: 40), kind: "Folder"),
        FileEntry(name: "a.png", isFolder: false, size: 200, modified: Date(timeIntervalSince1970: 20), kind: "PNG image"),
    ]

    private func names(_ key: FileSortKey, ascending: Bool = true, showHidden: Bool = true) -> [String] {
        FileSorting.sorted(FileSorting.visible(entries, showHidden: showHidden), by: key, ascending: ascending).map(\.name)
    }

    func testNameSortIsFinderLikeWithFoldersFirst() {
        XCTAssertEqual(names(.name), ["Docs", "src", ".hidden", "a.png", "File2.txt", "file10.txt"])
        XCTAssertEqual(names(.name, ascending: false), ["src", "Docs", "file10.txt", "File2.txt", "a.png", ".hidden"])
    }

    func testSizeDateAndKind() {
        // Folders have no size: they keep name order whichever way the files go.
        XCTAssertEqual(names(.size), ["Docs", "src", ".hidden", "File2.txt", "a.png", "file10.txt"])
        XCTAssertEqual(names(.size, ascending: false), ["Docs", "src", "file10.txt", "a.png", "File2.txt", ".hidden"])
        XCTAssertEqual(names(.modified, ascending: false), ["Docs", "src", ".hidden", "file10.txt", "a.png", "File2.txt"])
        XCTAssertEqual(names(.kind), ["Docs", "src", ".hidden", "a.png", "File2.txt", "file10.txt"])
    }

    func testHiddenEntriesOnlyWhenAsked() {
        XCTAssertFalse(names(.name, showHidden: false).contains(".hidden"))
        XCTAssertEqual(names(.name, showHidden: false).count, 5)
    }
}

final class FileNamesTests: XCTestCase {
    private func keepBoth(_ name: String, folder: Bool = false, existing: Set<String> = []) -> String {
        FileNames.keepBoth(name, isFolder: folder) { existing.contains($0) }
    }

    func testKeepBothNumbersLikeTheFinder() {
        XCTAssertEqual(keepBoth("photo.jpg"), "photo 2.jpg")
        XCTAssertEqual(keepBoth("photo.jpg", existing: ["photo 2.jpg", "photo 3.jpg"]), "photo 4.jpg")
        XCTAssertEqual(keepBoth("photo 2.jpg"), "photo 3.jpg")
        XCTAssertEqual(keepBoth("Folder", folder: true), "Folder 2")
        XCTAssertEqual(keepBoth("v1.2", folder: true), "v1.2 2")
        XCTAssertEqual(keepBoth("archive.tar.gz"), "archive.tar 2.gz")
        XCTAssertEqual(keepBoth(".zshrc"), ".zshrc 2")
        XCTAssertEqual(keepBoth("README"), "README 2")
        XCTAssertEqual(keepBoth("trailing."), "trailing. 2")
        // 1 is never a copy counter: it stays part of the name.
        XCTAssertEqual(keepBoth("Track 1.mp3"), "Track 1 2.mp3")
        XCTAssertEqual(keepBoth("Track 5.mp3"), "Track 6.mp3")
        XCTAssertEqual(keepBoth("2"), "2 2")
    }

    func testValidNames() {
        XCTAssertTrue(FileNames.isValid("notes.md"))
        XCTAssertTrue(FileNames.isValid(".env"))
        XCTAssertFalse(FileNames.isValid(""))
        XCTAssertFalse(FileNames.isValid("."))
        XCTAssertFalse(FileNames.isValid(".."))
        XCTAssertFalse(FileNames.isValid("a/b"))
        XCTAssertFalse(FileNames.isValid(String(repeating: "x", count: 256)))
    }

    func testSameOrInside() {
        XCTAssertTrue(FileNames.isSameOrInside("/a/b", "/a/b"))
        XCTAssertTrue(FileNames.isSameOrInside("/a/b/c", "/a/b/"))
        XCTAssertTrue(FileNames.isSameOrInside("/a/b/../b/c", "/a/b"))
        XCTAssertFalse(FileNames.isSameOrInside("/a/bc", "/a/b"))
        XCTAssertFalse(FileNames.isSameOrInside("/a", "/a/b"))
        XCTAssertTrue(FileNames.isSameOrInside("/x", "/"))
    }
}

final class ShellQuotingTests: XCTestCase {
    func testBackslashEscapes() {
        XCTAssertEqual(ShellQuoting.quote("/Users/me/plain-name_1.txt"), "/Users/me/plain-name_1.txt")
        XCTAssertEqual(ShellQuoting.quote("/tmp/My File (1).txt"), "/tmp/My\\ File\\ \\(1\\).txt")
        XCTAssertEqual(ShellQuoting.quote("/tmp/it's $HOME & *?"), "/tmp/it\\'s\\ \\$HOME\\ \\&\\ \\*\\?")
        XCTAssertEqual(ShellQuoting.quote("/tmp/~a^b%c"), "/tmp/\\~a\\^b\\%c")
        XCTAssertEqual(ShellQuoting.quote("/tmp/日本語 ファイル"), "/tmp/日本語\\ ファイル")
    }

    func testControlCharactersUseSingleQuotes() {
        XCTAssertEqual(ShellQuoting.quote("/tmp/two\nlines"), "'/tmp/two\nlines'")
        XCTAssertEqual(ShellQuoting.quote("/tmp/it's\nx"), "'/tmp/it'\\''s\nx'")
    }

    func testSeveralPaths() {
        XCTAssertEqual(ShellQuoting.quote(["/a b", "/c"]), "/a\\ b /c")
    }
}

final class GitStatusTests: XCTestCase {
    private func porcelain(_ records: [String]) -> Data { Data(records.joined(separator: "\0").appending("\0").utf8) }

    func testParse() {
        let changes = GitStatus.parse(porcelain([
            " M App/main.swift", "M  README.md", "A  new.txt", "R  pages/new name.md", "pages/old.md",
            "?? build/", "?? notes.txt", "UU conflict.swift", " D gone.txt",
        ]))
        XCTAssertEqual(changes.map(\.path), ["App/main.swift", "README.md", "new.txt", "pages/new name.md", "build/",
                                             "notes.txt", "conflict.swift", "gone.txt"])
        XCTAssertEqual(changes.map(\.state), [.modified, .modified, .added, .renamed, .untracked, .untracked, .conflicted, .deleted])
    }

    func testStatesPerFolderEntry() {
        let changes = GitStatus.parse(porcelain([
            " M App/Sources/a.swift", "?? App/Sources/new.swift", "A  App/b.swift", "?? App/Tmp/", " M top.txt",
        ]))
        XCTAssertEqual(GitStatus.states(changes, prefix: ""), ["App": .modified, "top.txt": .modified])
        XCTAssertEqual(GitStatus.states(changes, prefix: "App/"), ["Sources": .modified, "b.swift": .added, "Tmp": .untracked])
        XCTAssertEqual(GitStatus.states(changes, prefix: "App/Sources/"), ["a.swift": .modified, "new.swift": .untracked])
        XCTAssertEqual(GitStatus.states(changes, prefix: "Other/"), [:])
    }
}

final class FilesSyncTests: XCTestCase {
    func testFilesPanesBecomeBrowserPanesForOlderPhones() {
        let files = PaneInfo(id: "p2", kind: .files, title: "src", focused: false, attention: false,
                             workingDirectory: "/Users/me/my src")
        let preview = PaneInfo(id: "p3", kind: .preview, title: "a.md", focused: false, attention: false, file: "/tmp/a.md")
        let terminal = PaneInfo(id: "p1", kind: .terminal, title: "zsh", focused: true, attention: false, workingDirectory: "/tmp")
        let state = ServerMessage.State(workspaces: [WorkspaceInfo(id: "w1", title: "src", selected: true,
                                                                   panes: [terminal, files, preview])])
        XCTAssertTrue(state.hasFilesPanes)

        let legacy = state.forPhone(supportsPreview: true, supportsFiles: false).workspaces[0].panes
        XCTAssertEqual(legacy.map(\.kind), [.terminal, .browser, .preview])
        XCTAssertEqual(legacy[1].url, "file:///Users/me/my%20src/")
        XCTAssertNil(legacy[1].workingDirectory)

        let oldest = state.forPhone(supportsPreview: false, supportsFiles: false).workspaces[0].panes
        XCTAssertEqual(oldest.map(\.kind), [.terminal, .browser, .browser])

        XCTAssertEqual(state.forPhone(supportsPreview: true, supportsFiles: true), state)
    }

    func testBundleCarriesFilesPanes() throws {
        let bundle = WorkspaceBundle(workspaces: [
            .init(title: nil, workingDirectory: "/tmp", focusedPaneIndex: 0,
                  layout: .pane(WorkspaceBundle.Pane(kind: .files, path: "/tmp/a/../b"))),
        ])
        let checked = try bundle.validated()
        guard case .pane(let pane) = checked.workspaces[0].layout else { return XCTFail("not a pane") }
        XCTAssertEqual(pane.kind, .files)
        XCTAssertEqual(pane.path, "/tmp/b")

        let bad = WorkspaceBundle(workspaces: [
            .init(title: nil, workingDirectory: nil, focusedPaneIndex: 0,
                  layout: .pane(WorkspaceBundle.Pane(kind: .files, url: "https://example.com"))),
        ])
        XCTAssertThrowsError(try bad.validated())
    }

    func testRemoteSocketsCannotOpenFilesPanes() {
        let scope = RemoteScope(paneID: "p1", workspaceID: "w1")
        XCTAssertThrowsError(try RemoteAPIPolicy.authorize(method: "files.open", params: ["path": "/"], scope: scope)) { error in
            XCTAssertEqual((error as? RPCError)?.code, 403)
        }
    }
}
