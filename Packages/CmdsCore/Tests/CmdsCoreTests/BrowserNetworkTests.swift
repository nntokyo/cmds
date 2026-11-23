import Foundation
import XCTest
@testable import CmdsCore

/// The network record of browser panes (#174 G3): page records, failures, lines and filters.
final class BrowserNetworkTests: XCTestCase {
    func testRecordsFromThePage() {
        let fetch = NetworkEntry(message: ["kind": "fetch", "method": "post", "url": "http://x.test/api/save", "status": 500,
                                           "duration": 83.46, "time": 1_764_000_000_000, "size": 12, "page": "http://x.test/"])
        XCTAssertEqual(fetch?.kind, .fetch)
        XCTAssertEqual(fetch?.method, "POST")
        XCTAssertEqual(fetch?.status, 500)
        XCTAssertEqual(fetch?.duration, 83.5)
        XCTAssertEqual(fetch?.time, 1_764_000_000)
        XCTAssertNil(NetworkEntry(message: ["kind": "fetch"]), "no URL")
        XCTAssertNil(NetworkEntry(message: ["kind": "ws", "url": "x"]), "unknown kind")
        XCTAssertNil(NetworkEntry(message: ["kind": "resource", "url": "http://x.test/a.png", "size": 0])?.size, "0 bytes: unknown")
    }

    func testFailed() {
        func entry(_ status: Int?, error: String? = nil, kind: NetworkEntry.Kind = .fetch) -> NetworkEntry {
            NetworkEntry(kind: kind, url: "u", status: status, error: error, time: 0)
        }
        XCTAssertFalse(entry(200).failed)
        XCTAssertFalse(entry(304).failed)
        XCTAssertTrue(entry(404).failed)
        XCTAssertTrue(entry(503).failed)
        XCTAssertTrue(entry(0, error: "TypeError: Load failed").failed)
        XCTAssertTrue(entry(0).failed)
        XCTAssertFalse(entry(nil, kind: .resource).failed, "resources have no status")
    }

    func testLine() {
        let entry = NetworkEntry(kind: .fetch, method: "POST", url: "http://x.test/api/save", status: 500, duration: 83,
                                 size: 2_048, time: 0)
        XCTAssertEqual(entry.line(timeZone: TimeZone(identifier: "UTC")!),
                       "00:00:00  POST  500    83 ms  fetch    http://x.test/api/save  2.0 KB")
        let failed = NetworkEntry(kind: .xhr, method: "GET", url: "http://x.test/a", status: 0, error: "timeout", time: 0)
        XCTAssertTrue(failed.line(timeZone: TimeZone(identifier: "UTC")!).hasSuffix("xhr      http://x.test/a  (timeout)"))
        let image = NetworkEntry(kind: .resource, url: "http://x.test/logo.png", duration: 5, initiator: "img", time: 0)
        XCTAssertTrue(image.line(timeZone: TimeZone(identifier: "UTC")!).contains("-       5 ms  img      http://x.test/logo.png"))
    }

    func testBufferFilters() throws {
        var buffer = NetworkBuffer(capacity: 3)
        buffer.append(NetworkEntry(kind: .resource, url: "a.js", initiator: "script", time: 0))
        buffer.append(NetworkEntry(kind: .fetch, method: "GET", url: "ok", status: 200, time: 0))
        buffer.append(NetworkEntry(kind: .fetch, method: "GET", url: "missing", status: 404, time: 0))
        buffer.append(NetworkEntry(kind: .xhr, method: "GET", url: "down", status: 0, error: "error", time: 0))
        XCTAssertEqual(buffer.dropped, 1, "the cap drops the oldest")
        XCTAssertEqual(buffer.entries(BrowserNetworkRequest()).map(\.url), ["ok", "missing", "down"])
        XCTAssertEqual(buffer.entries(BrowserNetworkRequest(failed: true)).map(\.url), ["missing", "down"])
        XCTAssertEqual(buffer.entries(BrowserNetworkRequest(since: 2)).map(\.url), ["missing", "down"])
        XCTAssertEqual(buffer.entries(BrowserNetworkRequest(limit: 1)).map(\.url), ["down"])
        let json = buffer.json(BrowserNetworkRequest())
        XCTAssertEqual(json["last"], .number(4))
        XCTAssertEqual(json["dropped"], .number(1))
        var withResources = NetworkBuffer()
        withResources.append(NetworkEntry(kind: .resource, url: "a.js", initiator: "script", time: 0))
        XCTAssertTrue(withResources.entries(BrowserNetworkRequest()).isEmpty, "fetch and XHR only by default")
        XCTAssertEqual(withResources.entries(BrowserNetworkRequest(includeResources: true)).count, 1)
    }

    func testRequestParams() throws {
        let request = try BrowserNetworkRequest(params: .object(["failed": true, "resources": true, "limit": 5, "since": 2, "clear": true]))
        XCTAssertEqual(request, BrowserNetworkRequest(failed: true, includeResources: true, since: 2, limit: 5, clear: true))
        XCTAssertEqual(try BrowserNetworkRequest(params: .object(request.params.compactMapValues { $0 })), request)
        XCTAssertThrowsError(try BrowserNetworkRequest(params: .object(["limit": -1])))
        XCTAssertThrowsError(try BrowserNetworkRequest(params: .object(["failed": "yes"])))
    }
}
