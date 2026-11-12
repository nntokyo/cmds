import XCTest
@testable import CmdsCore

/// The end of an utterance, from the microphone's level relative to the room (#248, #270).
final class AssistantEndpointTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)
    /// One buffer of the microphone (2048 frames at 48 kHz).
    private let buffer = 0.043

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// Feeds `level(t)` buffer by buffer from `from` to `to`; the first time it says to finalise, or nil.
    @discardableResult
    private func feed(_ endpoint: inout AssistantEndpoint, from: TimeInterval, to: TimeInterval,
                      _ level: (TimeInterval) -> Float) -> TimeInterval? {
        var t = from
        var finalisedAt: TimeInterval?
        while t < to {
            endpoint.hear(level: level(t), at: at(t))
            if endpoint.shouldFinalize(now: at(t)), finalisedAt == nil { finalisedAt = t }
            t += buffer
        }
        return finalisedAt
    }

    func testSpeechThenQuietFinalisesOnce() {
        var endpoint = AssistantEndpoint()
        XCTAssertFalse(endpoint.shouldFinalize(now: at(0)), "nothing said")
        feed(&endpoint, from: 0, to: 2) { $0 < 1 ? 0.02 : 0.02 }
        XCTAssertNil(feed(&endpoint, from: 2, to: 3.5) { _ in 0.5 }, "speaking")
        let end = feed(&endpoint, from: 3.5, to: 6) { _ in 0.02 }
        XCTAssertEqual(end ?? 0, 3.5 + AssistantEndpoint.quiet, accuracy: 0.1)
        XCTAssertNil(feed(&endpoint, from: 6, to: 8) { _ in 0.02 }, "once per stretch of speech")
        XCTAssertNil(endpoint.speechStarted)
    }

    func testAPauseInsideASentenceKeepsItTogether() {
        var endpoint = AssistantEndpoint()
        feed(&endpoint, from: 0, to: 1) { _ in 0.02 }
        feed(&endpoint, from: 1, to: 2) { _ in 0.5 }
        XCTAssertNil(feed(&endpoint, from: 2, to: 2.5) { _ in 0.02 }, "half a second is a pause")
        feed(&endpoint, from: 2.5, to: 3) { _ in 0.5 }
        XCTAssertNotNil(feed(&endpoint, from: 3, to: 4.5) { _ in 0.02 })
    }

    func testAClickIsNoSpeech() {
        var endpoint = AssistantEndpoint()
        feed(&endpoint, from: 0, to: 1) { _ in 0.02 }
        // One buffer: shorter than `sustain`.
        XCTAssertNil(feed(&endpoint, from: 1, to: 4) { abs($0 - 1.5) < 0.02 ? 0.9 : 0.02 })
        XCTAssertNil(endpoint.speechStarted)
        // A few buffers: sound, but shorter than `minimumSpeech`; forgotten.
        XCTAssertNil(feed(&endpoint, from: 4, to: 6) { $0 > 4.5 && $0 < 4.65 ? 0.9 : 0.02 })
        XCTAssertNil(endpoint.speechStarted)
    }

    func testTheRecognisersOwnFinalStartsOver() {
        var endpoint = AssistantEndpoint()
        feed(&endpoint, from: 0, to: 1) { _ in 0.5 }
        endpoint.finalized()
        XCTAssertNil(feed(&endpoint, from: 1, to: 3) { _ in 0.02 })
    }

    func testTheFloorFollowsTheRoom() {
        var endpoint = AssistantEndpoint()
        feed(&endpoint, from: 0, to: 3) { _ in 0.02 }
        XCTAssertEqual(endpoint.floor ?? 0, 0.02, accuracy: 0.002)
        XCTAssertFalse(endpoint.isNoisy)
        XCTAssertEqual(endpoint.threshold, AssistantEndpoint.minimumLevel, "a quiet room: speech at least the minimum")
        // A café: the floor rises within seconds.
        feed(&endpoint, from: 3, to: 15) { _ in 0.25 }
        XCTAssertEqual(endpoint.floor ?? 0, 0.25, accuracy: 0.02)
        XCTAssertTrue(endpoint.isNoisy)
        XCTAssertEqual(endpoint.threshold, 0.25 * AssistantEndpoint.speechMargin, accuracy: 0.05)
        // Quiet again: it falls at once.
        feed(&endpoint, from: 15, to: 16.5) { _ in 0.02 }
        XCTAssertFalse(endpoint.isNoisy)
    }

    /// The case #270 is about: a loud room never drops to a quiet room's level, but speech ends 0.8 s after it stops.
    func testSpeechInANoisyRoomEnds() {
        var endpoint = AssistantEndpoint()
        // Noise around 0.25 (wobbling ±20 %), speech at 0.8 (well above it, as a voice at arm's length in a café).
        let noise: (TimeInterval) -> Float = { 0.25 * (1 + 0.2 * Float(sin($0 * 37))) }
        XCTAssertNil(feed(&endpoint, from: 0, to: 5, noise), "the noise alone is no speech")
        XCTAssertNil(feed(&endpoint, from: 5, to: 7) { _ in 0.8 })
        let end = feed(&endpoint, from: 7, to: 15, noise)
        XCTAssertNotNil(end)
        XCTAssertEqual(end ?? 0, 7 + AssistantEndpoint.quiet, accuracy: 0.15)
    }

    func testSofterWordsInsideSpeechInNoiseKeepItGoing() {
        var endpoint = AssistantEndpoint()
        feed(&endpoint, from: 0, to: 5) { _ in 0.25 }
        // 1.7 times the room: not enough to begin speech…
        XCTAssertNil(feed(&endpoint, from: 5, to: 5.3) { _ in 0.25 * 1.7 })
        XCTAssertNil(endpoint.speechStarted)
        feed(&endpoint, from: 5.3, to: 6) { _ in 0.8 }
        XCTAssertEqual(endpoint.threshold, (endpoint.floor ?? 0) * AssistantEndpoint.continueMargin, accuracy: 0.001)
        // …but enough to go on: longer than `quiet` without ending.
        var t = 6.0
        while t < 7 {
            endpoint.hear(level: (endpoint.floor ?? 0) * 1.7, at: at(t))
            XCTAssertFalse(endpoint.shouldFinalize(now: at(t)))
            t += buffer
        }
        XCTAssertNotNil(feed(&endpoint, from: 7, to: 9) { _ in 0.25 })
    }

    func testAlwaysLoudLeavesItToTheRecogniser() {
        var endpoint = AssistantEndpoint()
        // Speech-like sound all the time (a crowd talking right next to the microphone): the level never falls below
        // the floor's margin for long, so nothing is finalised early.
        XCTAssertNil(feed(&endpoint, from: 0, to: 30) { Float(0.3 + 0.5 * abs(sin($0 * 3))) })
    }
}

/// The name in a loud room, push to talk, and the microphone choice (#270).
final class AssistantNoisyAddressingTests: XCTestCase {
    private let names = AssistantAddressing.defaultNames

    func testANameHeardClearlyCountsInNoise() {
        let text = "ジャービス、状況は？"
        let clear = AssistantHeard(noisy: true, confidences: Array(repeating: 0.9, count: text.count))
        XCTAssertEqual(AssistantAddressing.check(text, names: names, followUpOpen: false, heard: clear), .command("状況は", byName: true))
    }

    func testAnUnsureNameIsDroppedInNoiseOnly() {
        let text = "Jarvis what's the status"
        // "Jarvis " unsure, the rest sure.
        let confidences = Array(repeating: 0.2, count: 7) + Array(repeating: 0.9, count: text.count - 7)
        XCTAssertEqual(AssistantAddressing.check(text, names: names, followUpOpen: false,
                                                 heard: AssistantHeard(noisy: true, confidences: confidences)), .ignored)
        XCTAssertEqual(AssistantAddressing.check(text, names: names, followUpOpen: false,
                                                 heard: AssistantHeard(noisy: false, confidences: confidences)),
                       .command("what's the status", byName: true), "a quiet room: as before")
        XCTAssertEqual(AssistantAddressing.check(text, names: names, followUpOpen: false, heard: AssistantHeard(noisy: true)),
                       .command("what's the status", byName: true), "no confidences: as before")
    }

    func testOnlyTheNamesConfidenceCounts() {
        // Leading space and a greeting: the name's characters are found in the untrimmed text.
        let text = " ねえジャービス、天気は"
        var confidences = Array(repeating: 0.9, count: text.count)
        confidences[text.count - 1] = 0.1
        XCTAssertEqual(AssistantAddressing.check(text, names: names, followUpOpen: false,
                                                 heard: AssistantHeard(noisy: true, confidences: confidences, text: text)),
                       .command("天気は", byName: true))
        confidences[3] = 0.1  // ジャ「ー」ビス
        XCTAssertEqual(AssistantAddressing.check(text, names: names, followUpOpen: false,
                                                 heard: AssistantHeard(noisy: true, confidences: confidences, text: text)), .ignored)
    }

    func testTheNameMustStillComeFirst() {
        // Someone else's words, then the name: not for the assistant, quiet or loud.
        XCTAssertEqual(AssistantAddressing.check("それでさ、ジャービスって映画見た？", names: names, followUpOpen: false,
                                                 heard: AssistantHeard(noisy: true)), .ignored)
    }

    func testInNoiseAFollowUpWithoutTheNameMustBeShort() {
        var machine = AssistantMachine()
        machine.turnOn()
        let now = Date(timeIntervalSince1970: 100)
        machine.hotkey(now: now)
        let long = "and then we went to the station and the train was late again so we took a taxi"
        XCTAssertEqual(machine.hear(long, names: names, now: now.addingTimeInterval(1), heard: AssistantHeard(noisy: true)), .ignore,
                       "talk around the user in a loud room")
        XCTAssertNotEqual(machine.hear(long, names: names, now: now.addingTimeInterval(1)), .ignore, "a quiet room: as before")
    }

    func testPushToTalkNeedsNoName() {
        var machine = AssistantMachine()
        machine.turnOn()
        let now = Date(timeIntervalSince1970: 100)
        // Held for longer than the follow-up window: still for the assistant.
        machine.hotkey(now: now)
        let step = machine.hear("状況は？", names: names, now: now.addingTimeInterval(AssistantMachine.followUpWindow + 5),
                                heard: AssistantHeard(noisy: true, pushed: true))
        guard case .handle = step else { return XCTFail("\(step)") }
    }

    func testPushToTalkReplacesACard() {
        var machine = AssistantMachine()
        machine.turnOn()
        let now = Date(timeIntervalSince1970: 100)
        let action = AssistantAction(kind: .reply, workspaceID: "w1", workspaceTitle: "api", paneID: "p1",
                                     paneTitle: "zsh", text: "run the tests", reasons: [])
        machine.answer("Send?", proposing: action, now: now)
        machine.speechFinished(now: now)
        XCTAssertEqual(machine.phase, .confirming)
        let step = machine.hear("状況は？", names: names, now: now.addingTimeInterval(1), heard: AssistantHeard(pushed: true))
        guard case .handle = step else { return XCTFail("\(step)") }
        XCTAssertNil(machine.pending)
    }

    func testListeningModes() {
        XCTAssertEqual(AssistantListening.standard, .automatic)
        XCTAssertFalse(AssistantListening.automatic.reducesNoise)
        XCTAssertTrue(AssistantListening.noiseReduction.reducesNoise)
        XCTAssertTrue(AssistantListening.pushToTalk.reducesNoise)
        XCTAssertTrue(AssistantListening.noiseReduction.listensAlways)
        XCTAssertFalse(AssistantListening.pushToTalk.listensAlways)
    }

    func testMicrophoneChoice() {
        let builtIn = AssistantInputDevice.Device(uid: "BuiltIn", name: "MacBook Pro Microphone", isHeadset: false)
        let airPods = AssistantInputDevice.Device(uid: "AirPods", name: "R's AirPods Pro", isHeadset: true)
        let usb = AssistantInputDevice.Device(uid: "USB", name: "USB Audio", isHeadset: false)
        XCTAssertNil(AssistantInputDevice.choose(AssistantInputDevice.automatic, devices: [builtIn, usb]), "no headset: the system's")
        XCTAssertEqual(AssistantInputDevice.choose(AssistantInputDevice.automatic, devices: [builtIn, airPods]), "AirPods")
        XCTAssertNil(AssistantInputDevice.choose(AssistantInputDevice.systemDefault, devices: [builtIn, airPods]))
        XCTAssertEqual(AssistantInputDevice.choose("USB", devices: [builtIn, airPods, usb]), "USB")
        XCTAssertEqual(AssistantInputDevice.choose("USB", devices: [builtIn, airPods]), "AirPods", "unplugged: automatic")
        XCTAssertNil(AssistantInputDevice.choose("USB", devices: [builtIn]))
        XCTAssertTrue(AssistantInputDevice.isHeadset(name: "Jabra", bluetooth: true))
        XCTAssertTrue(AssistantInputDevice.isHeadset(name: "Logitech USB Headset", bluetooth: false))
        XCTAssertFalse(AssistantInputDevice.isHeadset(name: "MacBook Pro Microphone", bluetooth: false))
    }
}
