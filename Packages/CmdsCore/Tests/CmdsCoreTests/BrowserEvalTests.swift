import XCTest
@testable import CmdsCore

/// `browser.eval`'s timeout and the English text of system errors in API replies (#338).
final class BrowserEvalTests: XCTestCase {
    func testTimeout() throws {
        XCTAssertEqual(try BrowserEval.timeout(params: nil), 30)
        XCTAssertEqual(try BrowserEval.timeout(params: ["script": "1", "timeout": .null]), 30)
        XCTAssertEqual(try BrowserEval.timeout(params: ["timeout": 2.5]), 2.5)
        XCTAssertEqual(try BrowserEval.timeout(params: ["timeout": 300]), 300)
        for bad: JSONValue in [0, -1, 301, "5", true] {
            XCTAssertThrowsError(try BrowserEval.timeout(params: ["timeout": bad]), "\(bad)") { error in
                XCTAssertEqual((error as? RPCError)?.code, -32602)
            }
        }
    }

    func testTimeoutMessage() {
        XCTAssertEqual(BrowserEval.timeoutMessage(seconds: 30, reloaded: false), "the script did not finish in 30 s")
        XCTAssertEqual(BrowserEval.timeoutMessage(seconds: 2.5, reloaded: true),
                       "the script did not finish in 2.5 s; the page stopped responding and was reloaded")
    }

    func testErrorText() {
        XCTAssertEqual(EnglishErrorText.message(domain: "WKErrorDomain", code: 5),
                       "the script's result is not a JSON-compatible value (return a string, number, boolean, array, object or null)")
        XCTAssertEqual(EnglishErrorText.message(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost),
                       "could not connect to the server")
        XCTAssertEqual(EnglishErrorText.message(domain: "WKErrorDomain", code: 999), "WebKit error 999")
        XCTAssertEqual(EnglishErrorText.message(domain: NSPOSIXErrorDomain, code: Int(ENOENT)), "No such file or directory")
        XCTAssertEqual(EnglishErrorText.message(domain: NSCocoaErrorDomain, code: 260, path: "/tmp/x"),
                       "NSCocoaErrorDomain error 260: /tmp/x")
        XCTAssertNil(EnglishErrorText.message(domain: "cmds.SomeError", code: 1))  // the app's own: English already
        // Every text is English ASCII (no app language leaks into API replies).
        for text in Array(EnglishErrorText.webKit.values) + Array(EnglishErrorText.urlLoading.values) {
            XCTAssertTrue(text.allSatisfy(\.isASCII), text)
        }
    }
}
