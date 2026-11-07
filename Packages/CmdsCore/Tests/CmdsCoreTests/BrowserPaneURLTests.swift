import XCTest
@testable import CmdsCore

final class BrowserPaneURLTests: XCTestCase {
    func testWebAddressesLoadOnThePhone() {
        for raw in ["https://example.com/", "http://192.168.1.20:8080/app", "https://docs.example.com/a?b=c#d"] {
            XCTAssertEqual(BrowserPaneURL.resolve(raw), .load(URL(string: raw)!), raw)
        }
    }

    func testPagesOnlyTheMacReaches() {
        for raw in ["http://localhost:3000/", "http://LOCALHOST/", "http://app.localhost:5173", "http://127.0.0.1:8000",
                    "http://[::1]:8080/", "http://0.0.0.0:4000", "file:///Users/me/index.html", "about:blank",
                    "ftp://example.com/", "not a url", ""] {
            XCTAssertEqual(BrowserPaneURL.resolve(raw), .macOnly, raw)
        }
        XCTAssertEqual(BrowserPaneURL.resolve(nil), .macOnly)
    }

    func testPhoneScreenViewport() {
        let page = MarkdownHTML.page("# Hi", title: "x.md")
        let phone = PreviewHTML.forPhoneScreen(page)
        XCTAssertTrue(phone.contains(#"<head><meta name="viewport" content="width=device-width, initial-scale=1">"#))
        XCTAssertEqual(phone.components(separatedBy: "viewport").count, 2, "one viewport tag")
        XCTAssertEqual(PreviewHTML.forPhoneScreen("<p>no head</p>"), "<p>no head</p>")
    }
}
