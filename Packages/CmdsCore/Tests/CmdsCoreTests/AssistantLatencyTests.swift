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
