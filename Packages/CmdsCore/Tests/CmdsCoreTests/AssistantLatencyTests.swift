import XCTest
@testable import CmdsCore

/// The assistant's stage times (#248).
final class AssistantTimelineTests: XCTestCase {
    func testStagesInMillisecondsFromHeard() {
        let start = Date(timeIntervalSince1970: 1000)
        var timeline = AssistantTimeline(request: 3, start: start)
        timeline.mark(.heard, at: start)
        timeline.mark(.speechEnd, at: start.addingTimeInterval(-0.6))
        timeline.mark(.routed, at: start.addingTimeInterval(0.004))
        timeline.mark(.claudeSpawn, at: start.addingTimeInterval(0.01))
        timeline.mark(.ack, at: start.addingTimeInterval(0.8))
        timeline.mark(.speechStart, at: start.addingTimeInterval(7.25))
        timeline.route = "web"
        XCTAssertEqual(timeline.milliseconds, ["heard": 0, "speechEnd": -600, "routed": 4, "claudeSpawn": 10, "ack": 800,
                                               "speechStart": 7250])
        XCTAssertEqual(timeline.firstSound, 800)
        XCTAssertEqual(timeline.summary, "web: speechEnd -600 heard 0 routed 4 claudeSpawn 10 ack 800 speechStart 7250 ms")
    }

    func testFirstMarkCountsExceptForTheEndOfACall() {
        let start = Date(timeIntervalSince1970: 0)
        var timeline = AssistantTimeline(request: 1, start: start)
        timeline.mark(.modelStart, at: start.addingTimeInterval(1))
        timeline.mark(.modelStart, at: start.addingTimeInterval(2))
        timeline.mark(.modelDone, at: start.addingTimeInterval(1.5))
        timeline.mark(.modelDone, at: start.addingTimeInterval(3))
        XCTAssertEqual(timeline.milliseconds["modelStart"], 1000)
        XCTAssertEqual(timeline.milliseconds["modelDone"], 3000)
        XCTAssertNil(timeline.firstSound)
        XCTAssertEqual(timeline.summary, "-: modelStart 1000 modelDone 3000 ms")
    }
}

/// The end of an utterance, from the microphone's level (#248).
final class AssistantEndpointTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testSpeechThenQuietFinalisesOnce() {
        var endpoint = AssistantEndpoint()
        XCTAssertFalse(endpoint.shouldFinalize(now: at(0)), "nothing said")
        for tick in stride(from: 0.0, through: 1.5, by: 0.05) { endpoint.loud(at: at(tick)) }
        XCTAssertFalse(endpoint.shouldFinalize(now: at(1.6)), "a pause shorter than quiet")
        XCTAssertFalse(endpoint.shouldFinalize(now: at(1.5 + AssistantEndpoint.quiet - 0.01)))
        XCTAssertTrue(endpoint.shouldFinalize(now: at(1.5 + AssistantEndpoint.quiet + 0.01)))
        XCTAssertFalse(endpoint.shouldFinalize(now: at(3)), "once per stretch of speech")
        XCTAssertNil(endpoint.speechStarted)
    }

    func testAPauseInsideASentenceKeepsItTogether() {
        var endpoint = AssistantEndpoint()
        endpoint.loud(at: at(0))
        endpoint.loud(at: at(1))
        XCTAssertFalse(endpoint.shouldFinalize(now: at(1.5)))
        endpoint.loud(at: at(1.6))
        XCTAssertFalse(endpoint.shouldFinalize(now: at(2.2)))
        XCTAssertTrue(endpoint.shouldFinalize(now: at(2.45)))
    }

    func testAClickIsNoSpeechAndIsForgotten() {
        var endpoint = AssistantEndpoint()
        endpoint.loud(at: at(0))
        endpoint.loud(at: at(0.1))
        XCTAssertFalse(endpoint.shouldFinalize(now: at(1)), "0.1 s of sound is no speech")
        XCTAssertNil(endpoint.speechStarted, "forgotten")
        endpoint.loud(at: at(5))
        XCTAssertFalse(endpoint.shouldFinalize(now: at(6)), "the click does not join later sound")
    }

    func testTheRecognisersOwnFinalStartsOver() {
        var endpoint = AssistantEndpoint()
        endpoint.loud(at: at(0))
        endpoint.loud(at: at(1))
        endpoint.finalized()
        XCTAssertFalse(endpoint.shouldFinalize(now: at(3)))
    }

    func testANoisyRoomNeverFinalisesEarly() {
        var endpoint = AssistantEndpoint()
        for tick in stride(from: 0.0, through: 30, by: 0.05) {
            endpoint.loud(at: at(tick))
            XCTAssertFalse(endpoint.shouldFinalize(now: at(tick)))
        }
    }
}
