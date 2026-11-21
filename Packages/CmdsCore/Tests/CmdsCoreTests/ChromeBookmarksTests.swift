import XCTest
@testable import CmdsCore

final class ChromeBookmarksTests: XCTestCase {
    private let sample = """
    {"checksum": "x", "version": 1, "roots": {
      "bookmark_bar": {"type": "folder", "name": "Bookmarks bar", "children": [
        {"type": "url", "name": "Example", "url": "https://example.com/"},
        {"type": "url", "name": "", "url": "http://localhost:3000/a"},
        {"type": "url", "name": "Bookmarklet", "url": "javascript:alert(1)"},
        {"type": "url", "name": "Settings", "url": "chrome://settings"},
        {"type": "folder", "name": "Dev", "children": [
          {"type": "url", "name": "Docs", "url": "file:///Users/me/docs/index.html"},
          {"type": "folder", "name": "Empty", "children": []}
        ]}
      ]},
      "other": {"type": "folder", "name": "Other bookmarks", "children": [
        {"type": "url", "name": "Other", "url": "https://other.example/"}
      ]},
      "synced": {"type": "folder", "name": "Mobile bookmarks", "children": []}
    }}
    """

    func testParsesFoldersAndLinks() throws {
        let tree = try XCTUnwrap(ChromeBookmarks.parse(Data(sample.utf8)))
        XCTAssertEqual(tree.bar, [
            .link(title: "Example", url: URL(string: "https://example.com/")!),
            .link(title: "localhost", url: URL(string: "http://localhost:3000/a")!),
            .folder(title: "Dev", items: [
                .link(title: "Docs", url: URL(string: "file:///Users/me/docs/index.html")!),
                .folder(title: "Empty", items: []),
            ]),
        ], "javascript: and chrome: links are left out; a link without a name shows its host")
        XCTAssertEqual(tree.other, [.link(title: "Other", url: URL(string: "https://other.example/")!)])
        XCTAssertEqual(tree.mobile, [])
        XCTAssertFalse(tree.isEmpty)
    }

    func testRejectsOtherFiles() {
        XCTAssertNil(ChromeBookmarks.parse(Data("[]".utf8)))
        XCTAssertNil(ChromeBookmarks.parse(Data("{\"version\": 1}".utf8)))
        XCTAssertNil(ChromeBookmarks.parse(Data("not json".utf8)))
    }

    func testDeepFoldersAreCut() throws {
        var json = "{\"type\": \"url\", \"name\": \"Deep\", \"url\": \"https://deep.example/\"}"
        for _ in 0..<(ChromeBookmarks.maxDepth + 5) {
            json = "{\"type\": \"folder\", \"name\": \"f\", \"children\": [\(json)]}"
        }
        let data = Data("{\"roots\": {\"bookmark_bar\": {\"children\": [\(json)]}}}".utf8)
        let tree = try XCTUnwrap(ChromeBookmarks.parse(data))
        func depth(_ items: [ChromeBookmarks.Item]) -> Int {
            items.map { item -> Int in
                if case .folder(_, let children) = item { return 1 + depth(children) }
                return 0
            }.max() ?? 0
        }
        XCTAssertLessThanOrEqual(depth(tree.bar), ChromeBookmarks.maxDepth)
    }

    func testProfilesFromLocalState() {
        let localState = """
        {"profile": {"last_used": "Profile 2", "info_cache": {
          "Profile 10": {"name": "Ten"}, "Profile 2": {"name": "Work"}, "Default": {"name": "Me"},
          "../evil": {"name": "Evil"}, "Profile 3": {}
        }}}
        """
        let result = ChromeBookmarks.profiles(localState: Data(localState.utf8))
        XCTAssertEqual(result.profiles.map(\.directory), ["Default", "Profile 2", "Profile 3", "Profile 10"])
        XCTAssertEqual(result.profiles.map(\.name), ["Me", "Work", "Profile 3", "Ten"])
        XCTAssertEqual(result.lastUsed, "Profile 2")
        XCTAssertTrue(ChromeBookmarks.profiles(localState: Data("{}".utf8)).profiles.isEmpty)
    }

    func testBookmarksFileFollowsTheLastUsedProfile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(ChromeBookmarks.bookmarksFile(profile: nil, chromeFolder: folder).path,
                       folder.appendingPathComponent("Default/Bookmarks").path, "no Local State: Default")
        try Data("{\"profile\": {\"last_used\": \"Profile 1\"}}".utf8).write(to: folder.appendingPathComponent("Local State"))
        XCTAssertEqual(ChromeBookmarks.bookmarksFile(profile: nil, chromeFolder: folder).path,
                       folder.appendingPathComponent("Profile 1/Bookmarks").path)
        XCTAssertEqual(ChromeBookmarks.bookmarksFile(profile: "Profile 4", chromeFolder: folder).path,
                       folder.appendingPathComponent("Profile 4/Bookmarks").path)
        XCTAssertEqual(ChromeBookmarks.bookmarksFile(profile: "../x", chromeFolder: folder).path,
                       folder.appendingPathComponent("Profile 1/Bookmarks").path, "a folder name leaving Chrome's is ignored")
    }

    func testAccountAndLocalBookmarksMerge() throws {
        let account = ChromeBookmarks.Tree(bar: [.link(title: "A", url: URL(string: "https://a.example/")!)],
                                           other: [.link(title: "O", url: URL(string: "https://o.example/")!)])
        let local = ChromeBookmarks.Tree(bar: [.link(title: "L", url: URL(string: "https://l.example/")!)])
        let merged = ChromeBookmarks.merged([account, local])
        XCTAssertEqual(merged.bar.map(\.title), ["A", "L"], "account bookmarks first, as Chrome shows them")
        XCTAssertEqual(merged.other.map(\.title), ["O"])
        XCTAssertEqual(ChromeBookmarks.fileNames, ["AccountBookmarks", "Bookmarks"])
        let folder = URL(fileURLWithPath: "/tmp/chrome-test-\(UUID().uuidString)")
        XCTAssertEqual(ChromeBookmarks.profileFolder(profile: "Profile 4", chromeFolder: folder).lastPathComponent, "Profile 4")
    }
}

final class BookmarkSourcesTests: XCTestCase {
    func testSafariPlist() throws {
        let plist: [String: Any] = ["Children": [
            ["Title": "BookmarksBar", "WebBookmarkType": "WebBookmarkTypeList", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://a.example/", "URIDictionary": ["title": "A"]],
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "javascript:alert(1)", "URIDictionary": ["title": "JS"]],
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "Dev", "Children": [
                    ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "http://b.example/x", "URIDictionary": [:]],
                ]],
            ]],
            ["Title": "BookmarksMenu", "WebBookmarkType": "WebBookmarkTypeList", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://m.example/", "URIDictionary": ["title": "M"]],
            ]],
            ["Title": "com.apple.ReadingList", "WebBookmarkType": "WebBookmarkTypeList", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://r.example/"],
            ]],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let tree = try XCTUnwrap(SafariBookmarks.parse(data))
        XCTAssertEqual(tree.bar, [
            .link(title: "A", url: URL(string: "https://a.example/")!),
            .folder(title: "Dev", items: [.link(title: "b.example", url: URL(string: "http://b.example/x")!)]),
        ])
        XCTAssertEqual(tree.other.map(\.title), ["M"], "the Bookmarks menu; no Reading List")
        XCTAssertNil(SafariBookmarks.parse(Data("not a plist".utf8)))
    }

    func testFolders() {
        let home = "/Users/me"
        XCTAssertEqual(BookmarkSource.chrome.folder(home: home).path, "/Users/me/Library/Application Support/Google/Chrome")
        XCTAssertEqual(BookmarkSource.brave.folder(home: home).path,
                       "/Users/me/Library/Application Support/BraveSoftware/Brave-Browser")
        XCTAssertEqual(BookmarkSource.safari.folder(home: home).path, "/Users/me/Library/Safari")
        XCTAssertTrue(BookmarkSource.edge.isChromium)
        XCTAssertFalse(BookmarkSource.safari.isChromium)
    }
}
