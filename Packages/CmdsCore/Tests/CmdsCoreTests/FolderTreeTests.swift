import Foundation
import XCTest
@testable import CmdsCore

final class FolderTreeTests: XCTestCase {
    func testRootStaysWhileInsideAndMovesWhenOutside() {
        XCTAssertEqual(FolderTree.root("/Users/me/app", showing: "/Users/me/app/src/ui"), "/Users/me/app")
        XCTAssertEqual(FolderTree.root("/Users/me/app", showing: "/Users/me/app"), "/Users/me/app")
        // Above the root, or beside it: the tree starts at the shown folder.
        XCTAssertEqual(FolderTree.root("/Users/me/app", showing: "/Users/me"), "/Users/me")
        XCTAssertEqual(FolderTree.root("/Users/me/app", showing: "/Users/me/application"), "/Users/me/application")
        XCTAssertEqual(FolderTree.root(nil, showing: "/tmp/x/../y"), "/tmp/y")
        XCTAssertEqual(FolderTree.root("/", showing: "/var/log"), "/")
    }

    func testChainOpensEveryFolderDownToTheShownOne() {
        XCTAssertEqual(FolderTree.chain(from: "/Users/me/app", to: "/Users/me/app/src/ui"),
                       ["/Users/me/app", "/Users/me/app/src", "/Users/me/app/src/ui"])
        XCTAssertEqual(FolderTree.chain(from: "/Users/me/app", to: "/Users/me/app"), ["/Users/me/app"])
        XCTAssertEqual(FolderTree.chain(from: "/", to: "/var/log"), ["/", "/var", "/var/log"])
        XCTAssertEqual(FolderTree.chain(from: "/Users/me/app", to: "/Users/me"), [])
        XCTAssertEqual(FolderTree.chain(from: "/a/b", to: "/a/bc"), [])
    }

    func testChildrenAreFoldersFirstByNameAndHideHiddenOnes() {
        let entries = [
            FileEntry(name: "b.txt", isFolder: false),
            FileEntry(name: ".git", isFolder: true, isHidden: true),
            FileEntry(name: "src", isFolder: true),
            FileEntry(name: "A.md", isFolder: false),
            FileEntry(name: "Docs", isFolder: true),
        ]
        XCTAssertEqual(FolderTree.children(entries, showHidden: false).map(\.name), ["Docs", "src", "A.md", "b.txt"])
        XCTAssertEqual(FolderTree.children(entries, showHidden: true).map(\.name), [".git", "Docs", "src", "A.md", "b.txt"])
    }

    func testNames() {
        XCTAssertEqual(FolderTree.name("/Users/me/app"), "app")
        XCTAssertEqual(FolderTree.name("/"), "/")
    }
}
