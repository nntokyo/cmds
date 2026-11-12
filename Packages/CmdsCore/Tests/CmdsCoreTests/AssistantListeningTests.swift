import XCTest
@testable import CmdsCore

/// How the assistant listens and which microphone (#270).
final class AssistantListeningTests: XCTestCase {
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
        XCTAssertEqual(AssistantInputDevice.chosen("USB", devices: [builtIn, airPods]), airPods)
        XCTAssertNil(AssistantInputDevice.chosen(AssistantInputDevice.systemDefault, devices: [builtIn, airPods]))
        XCTAssertFalse(AssistantInputDevice.isDevice(AssistantInputDevice.automatic))
        XCTAssertFalse(AssistantInputDevice.isDevice(AssistantInputDevice.systemDefault))
        XCTAssertTrue(AssistantInputDevice.isDevice("USB"))
        XCTAssertTrue(AssistantInputDevice.isHeadset(name: "Jabra", bluetooth: true))
        XCTAssertTrue(AssistantInputDevice.isHeadset(name: "Logitech USB Headset", bluetooth: false))
        XCTAssertFalse(AssistantInputDevice.isHeadset(name: "MacBook Pro Microphone", bluetooth: false))
    }

    func testRestartsAreLimited() {
        var restarts = AssistantListening.Restarts()
        let t0 = Date(timeIntervalSince1970: 0)
        for index in 0..<AssistantListening.restartLimit {
            XCTAssertTrue(restarts.allow(at: t0.addingTimeInterval(Double(index))))
        }
        XCTAssertFalse(restarts.allow(at: t0.addingTimeInterval(5)), "the sixth within 10 s")
        XCTAssertTrue(restarts.allow(at: t0.addingTimeInterval(AssistantListening.restartWindow + 5.5)), "the old ones expired")
    }
}
