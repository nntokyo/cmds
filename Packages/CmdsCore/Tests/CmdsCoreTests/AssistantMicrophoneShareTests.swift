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
        XCTAssertEqual(AssistantMicrophoneShare.recorders(processes, own: 10, ownBundleID: "tokyo.n-n.cmds").map(\.pid), [15, 500])
    }

    /// #295: release and Debug build both listening: only the released app answers, the Debug build stops for it.
    func testADebugBuildStopsForTheReleasedAppButNotTheOtherWayRound() {
        let release = AssistantMicrophoneShare.Process(pid: 11, bundleID: "tokyo.n-n.cmds", recording: true)
        let debug = AssistantMicrophoneShare.Process(pid: 10, bundleID: "tokyo.n-n.cmds.dev", recording: true)
        let other = AssistantMicrophoneShare.Process(pid: 12, bundleID: "tokyo.n-n.cmds.dev", recording: true)
        // The Debug build (PID 10): the released app counts, itself and another Debug instance do not.
        XCTAssertEqual(AssistantMicrophoneShare.recorders([release, debug, other], own: 10, ownBundleID: "tokyo.n-n.cmds.dev").map(\.pid), [11])
        // The released app (PID 11): no cmds counts, also not another released instance.
        let otherRelease = AssistantMicrophoneShare.Process(pid: 13, bundleID: "tokyo.n-n.cmds", recording: true)
        XCTAssertEqual(AssistantMicrophoneShare.recorders([release, debug, otherRelease], own: 11, ownBundleID: "tokyo.n-n.cmds").map(\.pid), [])
        // The released app not recording (its assistant off or paused): nothing.
        let quiet = AssistantMicrophoneShare.Process(pid: 11, bundleID: "tokyo.n-n.cmds", recording: false)
        XCTAssertEqual(AssistantMicrophoneShare.recorders([quiet], own: 10, ownBundleID: "tokyo.n-n.cmds.dev").map(\.pid), [])
        // Its own PID never counts, whatever its bundle ID.
        XCTAssertEqual(AssistantMicrophoneShare.recorders([release], own: 11, ownBundleID: "tokyo.n-n.cmds.dev").map(\.pid), [])
        XCTAssertTrue(AssistantMicrophoneShare.isDebugBuild("tokyo.n-n.cmds.dev"))
        XCTAssertFalse(AssistantMicrophoneShare.isDebugBuild("tokyo.n-n.cmds"))
        XCTAssertFalse(AssistantMicrophoneShare.isDebugBuild("com.example.dev"))
    }

    /// #305: two copies of the same build: the newer one (higher PID) stops while the older one listens.
    func testTheNewerOfTwoInstancesOfTheSameBuildStops() {
        let older = AssistantMicrophoneShare.Process(pid: 9, bundleID: "tokyo.n-n.cmds", recording: true)
        let newer = AssistantMicrophoneShare.Process(pid: 30, bundleID: "tokyo.n-n.cmds", recording: true)
        XCTAssertEqual(AssistantMicrophoneShare.recorders([older, newer], own: 30, ownBundleID: "tokyo.n-n.cmds").map(\.pid), [9])
        XCTAssertEqual(AssistantMicrophoneShare.recorders([older, newer], own: 9, ownBundleID: "tokyo.n-n.cmds").map(\.pid), [])
        let olderDev = AssistantMicrophoneShare.Process(pid: 9, bundleID: "tokyo.n-n.cmds.dev", recording: true)
        XCTAssertEqual(AssistantMicrophoneShare.recorders([olderDev], own: 30, ownBundleID: "tokyo.n-n.cmds.dev").map(\.pid), [9])
        XCTAssertTrue(AssistantMicrophoneShare.isCmds("tokyo.n-n.cmds.dev"))
        XCTAssertFalse(AssistantMicrophoneShare.isCmds("us.zoom.xos"))
    }

    /// #305: a command-line tool recording is known by its path and can be ignored by it.
    func testACommandLineToolIsIgnoredByItsPath() {
        let tool = AssistantMicrophoneShare.Process(pid: 40, bundleID: "/opt/homebrew/bin/sox", recording: true)
        XCTAssertEqual(AssistantMicrophoneShare.ignoreID(for: tool.bundleID), "/opt/homebrew/bin/sox")
        XCTAssertEqual(AssistantMicrophoneShare.ignoreID(for: "/Applications/X.app/Contents/MacOS/x.helper"),
                       "/Applications/X.app/Contents/MacOS/x.helper")
        XCTAssertEqual(AssistantMicrophoneShare.recorders([tool, zoom], own: 1, ownBundleID: "tokyo.n-n.cmds",
                                                          ignored: ["/opt/homebrew/bin/sox"]).map(\.pid), [500])
    }

    /// #295: apps the user chose never to stop for, by their ID or their helper's.
    func testIgnoredAppsAndTheirHelpersDoNotCount() {
        let processes: [AssistantMicrophoneShare.Process] = [
            .init(pid: 20, bundleID: "com.google.Chrome.helper", recording: true),
            .init(pid: 21, bundleID: "com.example.krisp", recording: true),
            zoom,
        ]
        let ignored: Set<String> = [AssistantMicrophoneShare.ignoreID(for: "com.google.Chrome.helper"), "com.example.krisp"]
        XCTAssertEqual(AssistantMicrophoneShare.ignoreID(for: "com.google.Chrome.helper"), "com.google.Chrome")
        XCTAssertEqual(AssistantMicrophoneShare.recorders(processes, own: 1, ownBundleID: "tokyo.n-n.cmds", ignored: ignored).map(\.pid), [500])
        // A raw helper ID in the list matches too.
        XCTAssertEqual(AssistantMicrophoneShare.recorders(processes, own: 1, ownBundleID: "tokyo.n-n.cmds",
                                                          ignored: ["com.google.Chrome.helper"]).map(\.pid), [21, 500])
    }

    /// #295: "Don't Pause for …" listens again at once; another app recording stops it again.
    func testIgnoringTheRecorderListensAgainAtOnce() {
        var share = AssistantMicrophoneShare()
        let krisp = AssistantMicrophoneShare.Process(pid: 21, bundleID: "com.example.krisp", recording: true)
        XCTAssertEqual(share.update(recorders: [krisp], listening: true, now: t0), .pause(pid: 21))
        share.recorderIgnored()
        XCTAssertNil(share.pausedFor)
        XCTAssertFalse(share.overridden)
        // The app is filtered out now (`recorders`): nothing records, nothing to resume.
        XCTAssertNil(share.update(recorders: [], listening: true, now: t0 + 1))
        XCTAssertNil(share.update(recorders: [], listening: true, now: t0 + 5))
        XCTAssertEqual(share.update(recorders: [zoom], listening: true, now: t0 + 6), .pause(pid: 500))
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
