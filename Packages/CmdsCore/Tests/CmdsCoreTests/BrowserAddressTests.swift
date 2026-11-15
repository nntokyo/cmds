import XCTest
@testable import CmdsCore

final class BrowserAddressTests: XCTestCase {
    private func resolve(_ input: String) -> String? {
        BrowserAddress.url(fromUserInput: input, homeDirectory: "/Users/me")?.absoluteString
    }

    private func isSearch(_ input: String) -> Bool {
        resolve(input)?.hasPrefix("https://www.google.com/search?q=") == true
    }

    func testFilePaths() {
        XCTAssertEqual(resolve("/tmp/x.html"), "file:///tmp/x.html")
        XCTAssertEqual(resolve("~/x.html"), "file:///Users/me/x.html")
        XCTAssertEqual(resolve("/tmp/my page.html"), "file:///tmp/my%20page.html")
        XCTAssertEqual(resolve("file:///tmp/x.html"), "file:///tmp/x.html")
    }

    func testSchemesAreKept() {
        XCTAssertEqual(resolve("mailto:a@b.com"), "mailto:a@b.com")
        XCTAssertEqual(resolve("mailto:a@b.com?subject=hi there"), "mailto:a@b.com?subject=hi%20there")
        XCTAssertEqual(resolve("tel:+81312345678"), "tel:+81312345678")
        XCTAssertEqual(resolve("tel:+81 3 1234 5678"), "tel:+81%203%201234%205678")
        XCTAssertEqual(resolve("about:blank"), "about:blank")
        XCTAssertEqual(resolve("https://example.com/a b"), "https://example.com/a%20b")
        XCTAssertEqual(resolve("http://localhost:3000/"), "http://localhost:3000/")
        XCTAssertTrue(BrowserAddress.opensExternally(URL(string: "mailto:a@b.com")!))
        XCTAssertTrue(BrowserAddress.opensExternally(URL(string: "TEL:+8131234")!))
        XCTAssertFalse(BrowserAddress.opensExternally(URL(string: "https://example.com")!))
        XCTAssertTrue(BrowserAddress.loadsInPane(URL(string: "about:blank")!))
        XCTAssertFalse(BrowserAddress.loadsInPane(URL(string: "zoommtg://x")!))
    }

    func testLocalHostsUseHTTP() {
        XCTAssertEqual(resolve("localhost"), "http://localhost")
        XCTAssertEqual(resolve("localhost:3000/app"), "http://localhost:3000/app")
        XCTAssertEqual(resolve("app.localhost:5173"), "http://app.localhost:5173")
        XCTAssertEqual(resolve("127.0.0.1:8000"), "http://127.0.0.1:8000")
        XCTAssertEqual(resolve("192.168.1.20/x"), "http://192.168.1.20/x")
        XCTAssertEqual(resolve("[::1]:8080"), "http://[::1]:8080")
        XCTAssertEqual(resolve("devbox:8080"), "http://devbox:8080")
    }

    func testDomainsUseHTTPS() {
        XCTAssertEqual(resolve("example.com"), "https://example.com")
        XCTAssertEqual(resolve("localhostfoo.com"), "https://localhostfoo.com")
        XCTAssertEqual(resolve("docs.example.co.uk/a?b=c#d"), "https://docs.example.co.uk/a?b=c#d")
        XCTAssertEqual(resolve("claude.ai"), "https://claude.ai")
        XCTAssertEqual(resolve("xn--wgv71a.xn--q9jyb4c"), "https://xn--wgv71a.xn--q9jyb4c")
    }

    func testEverythingElseIsSearched() {
        for input in ["1.5", "README.md", "main.rs", "package.json", "hello world", "swift", "foo:bar", "a@b.com",
                      "javascript:alert(1)", "-x.com", "1.2.3"] {
            XCTAssertTrue(isSearch(input), input)
        }
        XCTAssertEqual(resolve("1.5"), "https://www.google.com/search?q=1.5")
    }

    func testNothingToLoad() {
        for input in ["", "   ", "http://exa mple.com", "http://", "https:///path"] {
            XCTAssertNil(resolve(input), input)
        }
    }

    func testLoadErrorReasons() {
        XCTAssertEqual(BrowserLoadError.reason(domain: "NSURLErrorDomain", code: -1004),
                       "could not connect to the server (NSURLErrorDomain -1004)")
        XCTAssertEqual(BrowserLoadError.reason(domain: "Other", code: 7), "load failed (Other 7)")
        XCTAssertTrue(BrowserLoadError.isCertificateError(domain: "NSURLErrorDomain", code: -1202))
        XCTAssertFalse(BrowserLoadError.isCertificateError(domain: "NSURLErrorDomain", code: -1004))
        XCTAssertTrue(BrowserLoadError.isIgnored(domain: "NSURLErrorDomain", code: -999))
        XCTAssertTrue(BrowserLoadError.isIgnored(domain: "WebKitErrorDomain", code: 102))
        XCTAssertFalse(BrowserLoadError.isIgnored(domain: "NSURLErrorDomain", code: -1007))
    }
}
