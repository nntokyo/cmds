import Foundation
import XCTest
@testable import CmdsCore

/// Reload on file changes (#252): which pages and paths count, the request and the debounce.
final class BrowserWatchTests: XCTestCase {
    func testLocalPages() {
        for local in ["file:///Users/me/site/index.html", "http://localhost:3000/", "https://LOCALHOST/x",
                      "http://app.localhost:5173", "http://127.0.0.1:8080", "http://127.1.2.3/", "http://[::1]:4000/",
                      "http://0.0.0.0:8000"] {
            XCTAssertTrue(BrowserWatch.isLocalPage(URL(string: local)!), local)
        }
        for remote in ["https://example.com", "http://localhost.example.com", "http://127.0.0.1.nip.io",
                       "http://192.168.1.10:3000", "http://128.0.0.1", "about:blank", "data:text/html,hi",
                       "http://127.0.0.256/"] {
            XCTAssertFalse(BrowserWatch.isLocalPage(URL(string: remote)!), remote)
        }
    }

    func testReloadsOnlyLocalPagesUnlessRemote() {
        let watch = BrowserWatch(folder: "/p")
        XCTAssertTrue(watch.reloads(URL(string: "http://localhost:3000")))
        XCTAssertFalse(watch.reloads(URL(string: "https://example.com")))
        XCTAssertFalse(watch.reloads(nil))
        let remote = BrowserWatch(folder: "/p", remote: true)
        XCTAssertTrue(remote.reloads(URL(string: "https://example.com")))
        XCTAssertFalse(remote.reloads(URL(string: "about:blank")))
    }

    func testIgnoreRules() {
        let folder = "/Users/me/site"
        for kept in ["/Users/me/site/index.html", "/Users/me/site/src/app.js", "/Users/me/site/dist/main.css",
                     "/Users/me/site/builds/a.js", "/Users/me/site/src/node_modules_notes.md", "/Users/me/site/build"] {
            XCTAssertFalse(BrowserWatch.isIgnored(kept, folder: folder), kept)
        }
        // A folder's own event: the watched folder and ignored folders themselves are left out, other folders not.
        XCTAssertTrue(BrowserWatch.isIgnored(folder, folder: folder))
        XCTAssertTrue(BrowserWatch.isIgnored("/Users/me/site/build", folder: folder, isFolder: true))
        XCTAssertTrue(BrowserWatch.isIgnored("/Users/me/site/node_modules", folder: folder, isFolder: true))
        XCTAssertFalse(BrowserWatch.isIgnored("/Users/me/site/src", folder: folder, isFolder: true))
        XCTAssertTrue(BrowserWatch.isIgnored("/Users/me/site/build", folder: folder, keep: "/Users/me/site/build", isFolder: true))
        XCTAssertFalse(BrowserWatch.isIgnored("/Users/me/site/build/css", folder: folder, keep: "/Users/me/site/build", isFolder: true))
        for ignored in ["/Users/me/site/.git/index", "/Users/me/site/.git", "/Users/me/site/node_modules/x/y.js",
                        "/Users/me/site/build/out.js", "/Users/me/site/a/DerivedData/b", "/Users/me/site/.env",
                        "/Users/me/site/src/.app.js.swp", "/Users/me/site/index.html~", "/Users/me/site/.next/x.js",
                        "/Users/me/sitemap/index.html", "/Users/other/x.html", "/Users/me/site/target/debug/a"] {
            XCTAssertTrue(BrowserWatch.isIgnored(ignored, folder: folder), ignored)
        }
        // A page served from an ignored folder still reloads for its own files, not for its dot files.
        XCTAssertFalse(BrowserWatch.isIgnored("/Users/me/site/build/index.html", folder: folder, keep: "/Users/me/site/build"))
        XCTAssertFalse(BrowserWatch.isIgnored("/Users/me/site/build/css/a.css", folder: folder, keep: "/Users/me/site/build"))
        XCTAssertTrue(BrowserWatch.isIgnored("/Users/me/site/build/.DS_Store", folder: folder, keep: "/Users/me/site/build"))
        XCTAssertTrue(BrowserWatch.isIgnored("/Users/me/site/node_modules/a.js", folder: folder, keep: "/Users/me/site/build"))
        XCTAssertTrue(BrowserWatch.isIgnored("/Users/me/site/build/node_modules/a.js", folder: folder, keep: "/Users/me/site/build"))
        // The page in the watched folder itself (the usual case): the rules apply as without it.
        XCTAssertTrue(BrowserWatch.isIgnored("/Users/me/site/node_modules/pkg/a.js", folder: folder, keep: folder))
        XCTAssertTrue(BrowserWatch.isIgnored("/Users/me/site/.git/index", folder: folder, keep: folder))
        XCTAssertFalse(BrowserWatch.isIgnored("/Users/me/site/src/app.js", folder: folder, keep: folder))
        // A trailing slash on the folder, and the root folder.
        XCTAssertFalse(BrowserWatch.isIgnored("/Users/me/site/a.html", folder: folder + "/"))
        XCTAssertFalse(BrowserWatch.isIgnored("/tmp/a.html", folder: "/"))
        XCTAssertTrue(BrowserWatch.isIgnored("/tmp/.a.html", folder: "/"))
    }

    func testPageFolder() {
        XCTAssertEqual(BrowserWatch.pageFolder(URL(string: "file:///Users/me/site/build/index.html")), "/Users/me/site/build")
        XCTAssertNil(BrowserWatch.pageFolder(URL(string: "http://localhost/index.html")))
    }

    func testChange() throws {
        XCTAssertTrue(try BrowserWatchChange(params: nil).isQuery)
        XCTAssertTrue(try BrowserWatchChange(params: ["pane": "p1"]).isQuery)
        XCTAssertEqual(try BrowserWatchChange(params: ["dir": "/a/b/../c/"]).folder, "/a/c")
        XCTAssertTrue(try BrowserWatchChange(params: ["off": true]).off)
        XCTAssertTrue(try BrowserWatchChange(params: ["on": false]).off)
        XCTAssertTrue(try BrowserWatchChange(params: ["on": true]).turnsOn)
        for bad: JSONValue in [["dir": "relative/path"], ["off": true, "dir": "/a"], ["off": true, "remote": true],
                               ["dir": 3], ["remote": "yes"], ["on": false, "dir": "/a"]] {
            XCTAssertThrowsError(try BrowserWatchChange(params: bad), "\(bad)")
        }
        let change = BrowserWatchChange(folder: "/x", remote: true)
        XCTAssertEqual(try BrowserWatchChange(params: .object(change.params.compactMapValues { $0 })), change)
    }

    func testApplied() throws {
        let current = BrowserWatch(folder: "/old", remote: true)
        XCTAssertNil(try BrowserWatchChange(off: true).applied(to: current, defaultFolder: "/d"))
        XCTAssertEqual(try BrowserWatchChange().applied(to: current, defaultFolder: "/d"), current)
        XCTAssertNil(try BrowserWatchChange().applied(to: nil, defaultFolder: "/d"))
        var on = BrowserWatchChange()
        on.turnsOn = true
        XCTAssertEqual(try on.applied(to: nil, defaultFolder: "/d"), BrowserWatch(folder: "/d"))
        XCTAssertEqual(try on.applied(to: current, defaultFolder: "/d"), current)
        XCTAssertThrowsError(try on.applied(to: nil, defaultFolder: nil))
        XCTAssertEqual(try BrowserWatchChange(folder: "/new").applied(to: current, defaultFolder: "/d"),
                       BrowserWatch(folder: "/new", remote: true))
        XCTAssertEqual(try BrowserWatchChange(remote: true).applied(to: nil, defaultFolder: "/d"),
                       BrowserWatch(folder: "/d", remote: true))
    }

    func testJSONAndSummary() {
        let json = BrowserWatch.json(BrowserWatch(folder: "/p"), active: true)
        XCTAssertEqual(json, ["on": true, "folder": "/p", "remote": false, "active": true])
        XCTAssertEqual(BrowserWatch.summary(json), "watching /p")
        XCTAssertEqual(BrowserWatch.summary(BrowserWatch.json(nil)), "off")
        XCTAssertEqual(BrowserWatch.summary(BrowserWatch.json(BrowserWatch(folder: "/p", remote: true), active: false)),
                       "watching /p (remote pages too) (paused: pane not on screen or page not local)")
    }

    func testJSONAndSummaryWithProblem() {
        let json = BrowserWatch.json(BrowserWatch(folder: "/p"), active: false, problem: .folderMissing)
        XCTAssertEqual(json, ["on": true, "folder": "/p", "remote": false, "active": false,
                              "error": "the folder was removed or moved"])
        XCTAssertEqual(BrowserWatch.summary(json), "watching /p (not watching: the folder was removed or moved)")
        let cannot = BrowserWatch.json(BrowserWatch(folder: "/p"), active: false, problem: .cannotWatch)
        XCTAssertEqual(BrowserWatch.summary(cannot), "watching /p (not watching: cannot watch the folder)")
        // Off: no error to report.
        XCTAssertEqual(BrowserWatch.json(nil, problem: .cannotWatch), ["on": false, "remote": false])
    }

    func testDebounce() {
        var debounce = WatchDebounce()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(debounce.change(at: t0), t0.addingTimeInterval(0.3))
        XCTAssertEqual(debounce.change(at: t0.addingTimeInterval(0.2)), t0.addingTimeInterval(0.5))
        // Changes every 0.2 s: the ceiling, 2 s after the first, wins.
        XCTAssertEqual(debounce.change(at: t0.addingTimeInterval(1.9)), t0.addingTimeInterval(2))
        debounce.reset()
        XCTAssertNil(debounce.firstPending)
        XCTAssertEqual(debounce.change(at: t0.addingTimeInterval(3)), t0.addingTimeInterval(3.3))
    }
}
