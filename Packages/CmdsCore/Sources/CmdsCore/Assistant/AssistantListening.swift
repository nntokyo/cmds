import Foundation

/// How the assistant listens (#270, Settings › Assistant › Listening).
public enum AssistantListening: String, CaseIterable, Sendable {
    /// The microphone as it is; an utterance ends by its level (`AssistantEndpoint`).
    case automatic
    /// The same with the system's voice processing on the microphone: noise suppression and echo cancellation.
    case noiseReduction
    /// Only while the listen shortcut is held (a very loud place): letting go ends the utterance at once. With noise
    /// reduction too.
    case pushToTalk

    /// Automatic: voice processing could only be checked with a real microphone, and it ducks other apps' sound while
    /// it runs, so it is the user's choice.
    public static let standard: AssistantListening = .automatic

    /// The system's voice processing (noise suppression, echo cancellation) on the input.
    public var reducesNoise: Bool { self != .automatic }
    /// Every utterance is heard (and needs the name); push to talk hears only what is said while the key is held.
    public var listensAlways: Bool { self != .pushToTalk }

    /// Audio from just before the key went down that is still heard (the first syllable often starts with the press).
    public static let preRoll: TimeInterval = 0.3
    /// Audio after the key came up that is still heard (the last syllable often ends after the release).
    public static let releaseTail: TimeInterval = 0.2
}

/// Which microphone the assistant listens to (#270, Settings › Assistant › Microphone): a headset when one is
/// connected (closer to the mouth than the Mac's: much less of a loud room), else the system's input.
public enum AssistantInputDevice {
    public struct Device: Equatable, Sendable {
        /// The Core Audio device UID (stable across launches and reconnections).
        public var uid: String
        public var name: String
        /// Bluetooth (AirPods and other headsets) or a device named like a headset.
        public var isHeadset: Bool

        public init(uid: String, name: String, isHeadset: Bool) {
            self.uid = uid
            self.name = name
            self.isHeadset = isHeadset
        }
    }

    /// The setting: a headset when connected, else the system's input.
    public static let automatic = ""
    /// The setting: the input chosen in System Settings › Sound, always.
    public static let systemDefault = "system"

    /// Whether a device is a headset by its transport (`bluetooth`: Bluetooth or Bluetooth LE) or its name.
    public static func isHeadset(name: String, bluetooth: Bool) -> Bool {
        if bluetooth { return true }
        let name = name.lowercased()
        return ["headset", "headphone", "airpods", "earpods", "ヘッドセット", "ヘッドフォン", "ヘッドホン"].contains { name.contains($0) }
    }

    /// The device to listen to (its UID), nil for the system's input. A device chosen in Settings that is not
    /// connected (unplugged, out of range) counts as automatic until it comes back.
    public static func choose(_ setting: String, devices: [Device]) -> String? {
        if setting == systemDefault { return nil }
        if setting != automatic, devices.contains(where: { $0.uid == setting }) { return setting }
        return devices.first(where: \.isHeadset)?.uid
    }
}
