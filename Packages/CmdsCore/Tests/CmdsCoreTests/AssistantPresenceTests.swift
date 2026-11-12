import CoreGraphics
import XCTest
@testable import CmdsCore

/// What of the assistant is on screen: the waiting orb, the HUD or nothing; where the orb goes (#243).
final class AssistantPresenceTests: XCTestCase {
    func testOrbWhileWaitingHUDWhileActive() {
        func shown(_ phase: AssistantMachine.Phase, hud: Bool = false, show: Bool = true, attention: Bool = false,
                   hearing: Bool = false) -> AssistantPresence.Shown {
            AssistantPresence.shown(phase: phase, hudShown: hud, showWhileWaiting: show, attention: attention, hearing: hearing)
        }
        XCTAssertEqual(shown(.off), .none)
        XCTAssertEqual(shown(.idle), .orb(.standingBy))
        XCTAssertEqual(shown(.paused), .orb(.paused))
        XCTAssertEqual(shown(.idle, attention: true), .orb(.attention))
        XCTAssertEqual(shown(.idle, attention: true, hearing: true), .orb(.hearing))
        XCTAssertEqual(shown(.paused, hearing: true), .orb(.paused))
        XCTAssertEqual(shown(.listening, hud: true), .hud)
        XCTAssertEqual(shown(.idle, hud: true, show: false), .hud)
        XCTAssertEqual(shown(.off, hud: true), .hud, "a goodbye after turning off")
        XCTAssertEqual(shown(.idle, show: false), .none)
        XCTAssertEqual(shown(.paused, show: false), .none)
    }

    func testDefaultBottomRightAboveTheDock() {
        let visible = CGRect(x: 0, y: 80, width: 1440, height: 795)
        let center = AssistantPresence.center(saved: nil, side: 56, visibles: [visible])
        XCTAssertEqual(center, CGPoint(x: 1440 - 20 - 28, y: 80 + 20 + 28))
        XCTAssertEqual(AssistantPresence.Size.small.side, 56)
        XCTAssertGreaterThan(AssistantPresence.Size.medium.side, AssistantPresence.Size.small.side)
    }

    func testSavedPositionKeptInsideItsScreen() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let other = CGRect(x: 1440, y: 0, width: 1920, height: 1050)
        XCTAssertEqual(AssistantPresence.center(saved: CGPoint(x: 600, y: 400), side: 56, visibles: [main, other]),
                       CGPoint(x: 600, y: 400))
        XCTAssertEqual(AssistantPresence.center(saved: CGPoint(x: 2000, y: 500), side: 56, visibles: [main, other]),
                       CGPoint(x: 2000, y: 500))
        // Half off the edge: moved in.
        XCTAssertEqual(AssistantPresence.center(saved: CGPoint(x: 1430, y: 5), side: 56, visibles: [main]),
                       CGPoint(x: 1412, y: 28))
        // Dropped onto the Dock, below the visible frame: just above it on that screen.
        let aboveDock = CGRect(x: 0, y: 80, width: 1440, height: 795)
        XCTAssertEqual(AssistantPresence.center(saved: CGPoint(x: 800, y: 30), side: 56, visibles: [aboveDock]),
                       CGPoint(x: 800, y: 108))
        // The screen it was on is gone: the default on the main screen.
        XCTAssertEqual(AssistantPresence.center(saved: CGPoint(x: 2000, y: 500), side: 56, visibles: [main]),
                       AssistantPresence.defaultCenter(visible: main, side: 56))
    }

    func testStoredPosition() {
        XCTAssertEqual(AssistantPresence.parse("1380,108"), CGPoint(x: 1380, y: 108))
        XCTAssertEqual(AssistantPresence.parse(" -200, 40.5"), CGPoint(x: -200, y: 40.5))
        XCTAssertNil(AssistantPresence.parse(nil))
        XCTAssertNil(AssistantPresence.parse("1,2,3"))
        XCTAssertNil(AssistantPresence.parse("x,1"))
        XCTAssertNil(AssistantPresence.parse("nan,1"))
        XCTAssertEqual(AssistantPresence.format(CGPoint(x: 1380.4, y: 107.6)), "1380,108")
    }

    func testHearingHoldsBetweenWords() {
        var hearing = AssistantPresence.Hearing()
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(hearing.update(level: 0.05, now: start))
        XCTAssertTrue(hearing.update(level: 0.3, now: start))
        XCTAssertTrue(hearing.isHearing)
        // Between the on and off levels: still hearing, however long.
        XCTAssertFalse(hearing.update(level: 0.1, now: start.addingTimeInterval(2)))
        // Quiet, but not for long enough.
        XCTAssertFalse(hearing.update(level: 0.01, now: start.addingTimeInterval(3)))
        XCTAssertFalse(hearing.update(level: 0.01, now: start.addingTimeInterval(3.5)))
        XCTAssertTrue(hearing.isHearing)
        // A word again restarts the hold.
        hearing.update(level: 0.2, now: start.addingTimeInterval(3.55))
        XCTAssertFalse(hearing.update(level: 0.01, now: start.addingTimeInterval(3.6)))
        XCTAssertFalse(hearing.update(level: 0.01, now: start.addingTimeInterval(4.1)))
        XCTAssertTrue(hearing.update(level: 0.01, now: start.addingTimeInterval(4.2)))
        XCTAssertFalse(hearing.isHearing)
        hearing.update(level: 0.9, now: start.addingTimeInterval(5))
        hearing.reset()
        XCTAssertFalse(hearing.isHearing)
    }
}
