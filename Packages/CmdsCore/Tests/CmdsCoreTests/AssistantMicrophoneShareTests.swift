import CmdsCore
import XCTest

/// #278: the assistant stops listening while another app records, and listens again after.
final class AssistantMicrophoneShareTests: XCTestCase {
    private let zoom = AssistantMicrophoneShare.Process(pid: 500, bundleID: "us.zoom.xos", recording: true)
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testRecordersSkipItselfOtherCmdsAndSystemListeners() {
        let processes: [AssistantMicrophoneShare.Process] = [
            .init(pid: 10, bundleID: "tokyo.n-n.cmds.dev", recording: true),
            .init(pid: 11, bundleID: "tokyo.n-n.cmds", recording: true),
            .init(pid: 12, bundleID: "com.apple.CoreSpeech", recording: true),
            .init(pid: 13, bundleID: "com.apple.accessibility.heard", recording: true),
            .init(pid: 14, bundleID: "com.google.Chrome.helper", recording: false),
            .init(pid: 15, bundleID: "", recording: true),
            zoom,
        ]
        XCTAssertEqual(AssistantMicrophoneShare.recorders(processes, own: 10).map(\.pid), [15, 500])
    }

    func testPausesForACallAndResumesAfterItIsQuiet() {
        var share = AssistantMicrophoneShare()
        XCTAssertNil(share.update(recorders: [], listening: true, now: t0))
        XCTAssertEqual(share.update(recorders: [zoom], listening: true, now: t0), .pause(pid: 500))
        XCTAssertEqual(share.pausedFor, 500)
        // Paused now: still recording is no new change.
        XCTAssertNil(share.update(recorders: [zoom], listening: false, now: t0 + 1))
        XCTAssertNil(share.update(recorders: [], listening: false, now: t0 + 2))
        XCTAssertNil(share.update(recorders: [], listening: false, now: t0 + 3.5))
        XCTAssertEqual(share.update(recorders: [], listening: false, now: t0 + 4), .resume)
        XCTAssertNil(share.pausedFor)
        XCTAssertNil(share.update(recorders: [], listening: true, now: t0 + 10))
    }

    func testABriefGapInTheCallDoesNotResume() {
        var share = AssistantMicrophoneShare()
        _ = share.update(recorders: [zoom], listening: true, now: t0)
        XCTAssertNil(share.update(recorders: [], listening: false, now: t0 + 1))
        XCTAssertNil(share.update(recorders: [zoom], listening: false, now: t0 + 2))
        XCTAssertNil(share.update(recorders: [], listening: false, now: t0 + 3))
        XCTAssertNil(share.update(recorders: [], listening: false, now: t0 + 4))
        XCTAssertEqual(share.update(recorders: [], listening: false, now: t0 + 5), .resume)
    }

    func testNotListeningMeansNoPause() {
        var share = AssistantMicrophoneShare()
        XCTAssertNil(share.update(recorders: [zoom], listening: false, now: t0))
        XCTAssertNil(share.pausedFor)
        // The user's own pause is never resumed by the end of the call.
        XCTAssertNil(share.update(recorders: [], listening: false, now: t0 + 1))
        XCTAssertNil(share.update(recorders: [], listening: false, now: t0 + 5))
    }

    func testTheUserResumingDuringTheCallKeepsListeningUntilItEnds() {
        var share = AssistantMicrophoneShare()
        _ = share.update(recorders: [zoom], listening: true, now: t0)
        share.userResumed()
        XCTAssertTrue(share.overridden)
        XCTAssertNil(share.update(recorders: [zoom], listening: true, now: t0 + 1))
        // The call ends; the next one pauses again.
        XCTAssertNil(share.update(recorders: [], listening: true, now: t0 + 2))
        XCTAssertFalse(share.overridden)
        XCTAssertEqual(share.update(recorders: [zoom], listening: true, now: t0 + 60), .pause(pid: 500))
    }

    func testTheUserPausingDuringTheCallStaysPaused() {
        var share = AssistantMicrophoneShare()
        _ = share.update(recorders: [zoom], listening: true, now: t0)
        share.userPaused()
        XCTAssertNil(share.pausedFor)
        XCTAssertNil(share.update(recorders: [], listening: false, now: t0 + 1))
        XCTAssertNil(share.update(recorders: [], listening: false, now: t0 + 5))
    }

    func testAHelperBelongsToItsApp() {
        XCTAssertEqual(AssistantMicrophoneShare.appBundleID(ofHelper: "com.google.Chrome.helper"), "com.google.Chrome")
        XCTAssertEqual(AssistantMicrophoneShare.appBundleID(ofHelper: "com.microsoft.edgemac.helper.renderer"), "com.microsoft.edgemac")
        XCTAssertEqual(AssistantMicrophoneShare.appBundleID(ofHelper: "us.zoom.xos"), "us.zoom.xos")
    }
}
