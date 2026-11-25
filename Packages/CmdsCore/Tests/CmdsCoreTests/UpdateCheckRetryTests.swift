import XCTest
@testable import CmdsCore

final class UpdateCheckRetryTests: XCTestCase {
    private let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)

    /// What Sparkle reports when the feed cannot be loaded: its own error with the URL error two levels down.
    private var feedDownloadFailed: NSError {
        let temporary = NSError(domain: "SUSparkleErrorDomain", code: 2001, userInfo: [NSUnderlyingErrorKey: offline])
        return NSError(domain: "SUSparkleErrorDomain", code: 2001, userInfo: [NSUnderlyingErrorKey: temporary])
    }

    func testRetriesAfterANetworkFailure() {
        XCTAssertEqual(UpdateCheckRetry.retryDelay(after: feedDownloadFailed, attempt: 0), UpdateCheckRetry.delay)
        XCTAssertEqual(UpdateCheckRetry.retryDelay(after: offline, attempt: UpdateCheckRetry.maxAttempts - 1),
                       UpdateCheckRetry.delay)
    }

    func testGivesUpAfterTheLastAttempt() {
        XCTAssertNil(UpdateCheckRetry.retryDelay(after: feedDownloadFailed, attempt: UpdateCheckRetry.maxAttempts))
    }

    func testNoRetryForOtherErrors() {
        // No update found, a feed that does not parse, a signature that does not match.
        for code in [1001, 1000, 3001] {
            let error = NSError(domain: "SUSparkleErrorDomain", code: code)
            XCTAssertNil(UpdateCheckRetry.retryDelay(after: error, attempt: 0), "\(code)")
        }
    }
}
