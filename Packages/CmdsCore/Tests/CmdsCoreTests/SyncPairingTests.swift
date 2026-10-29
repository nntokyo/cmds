import XCTest
@testable import CmdsCore

final class SyncPairingTests: XCTestCase {
    func testCodeAndTokenFormat() {
        for _ in 0..<50 {
            let code = PairingToken.generateCode()
            XCTAssertTrue(PairingToken.isWellFormedCode(code), code)
        }
        let token = PairingToken.generate()
        XCTAssertEqual(token.count, 43)
        XCTAssertNil(token.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertNotEqual(token, PairingToken.generate())
        XCTAssertFalse(PairingToken.isWellFormedCode("12345"))
        XCTAssertFalse(PairingToken.isWellFormedCode("12345a"))
        XCTAssertFalse(PairingToken.isWellFormedCode("１２３４５６"))
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(PairingToken.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(PairingToken.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(PairingToken.constantTimeEquals("abc", "abcd"))
        XCTAssertFalse(PairingToken.constantTimeEquals("", "a"))
        XCTAssertTrue(PairingToken.constantTimeEquals("", ""))
        XCTAssertTrue(PairingToken.matchesAny("b", in: ["a", "b", "c"]))
        XCTAssertFalse(PairingToken.matchesAny("d", in: ["a", "b", "c"]))
    }

    func testAuthenticator() {
        let fresh = { "NEW" }
        func eval(_ hello: ClientMessage.Hello, code: String? = "123456") -> PairingAuthenticator.Outcome {
            PairingAuthenticator.evaluate(hello, currentCode: code, knownTokens: ["T1", "T2"], newToken: fresh)
        }
        XCTAssertEqual(eval(.init(deviceName: "d", token: "T2")), .accepted(token: "T2", isNewToken: false))
        XCTAssertEqual(eval(.init(deviceName: "d", pairingCode: "123456")), .accepted(token: "NEW", isNewToken: true))
        XCTAssertEqual(eval(.init(deviceName: "d", pairingCode: "123456", token: "stale")),
                       .accepted(token: "NEW", isNewToken: true))

        func code(_ outcome: PairingAuthenticator.Outcome) -> SyncErrorCode? {
            if case .rejected(let info) = outcome { return info.code }
            return nil
        }
        XCTAssertEqual(code(eval(.init(deviceName: "d", token: "stale"))), .invalidToken)
        XCTAssertEqual(code(eval(.init(deviceName: "d"))), .pairingRequired)
        XCTAssertEqual(code(eval(.init(deviceName: "d", pairingCode: "000000"))), .invalidPairingCode)
        XCTAssertEqual(code(eval(.init(deviceName: "d", pairingCode: "123456"), code: nil)), .invalidPairingCode)
        XCTAssertEqual(code(eval(.init(protocolVersion: 99, deviceName: "d", token: "T1"))), .unsupportedVersion)
        XCTAssertTrue(SyncErrorCode.invalidToken.isAuthFailure)
        XCTAssertFalse(SyncErrorCode.notFound.isAuthFailure)
    }

    func testBackoff() {
        var backoff = SyncBackoff(base: 1, cap: 8, jitter: 0)
        XCTAssertEqual((0..<6).map { _ in backoff.nextDelay() }, [1, 2, 4, 8, 8, 8])
        backoff.reset()
        XCTAssertEqual(backoff.nextDelay(), 1)
        var jittered = SyncBackoff(base: 10, cap: 10, jitter: 0.2)
        XCTAssertEqual(jittered.nextDelay(random: 0), 8, accuracy: 1e-9)
        XCTAssertEqual(jittered.nextDelay(random: 1), 12, accuracy: 1e-9)
    }
}
