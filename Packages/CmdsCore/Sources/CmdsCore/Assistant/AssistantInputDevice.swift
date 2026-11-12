import Foundation

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

    /// Whether the setting names one device (a UID), not automatic or the system's input.
    public static func isDevice(_ setting: String) -> Bool {
        setting != automatic && setting != systemDefault
    }

    /// Words (lowercased) in the name of a device that is a headset whatever its transport.
    static let headsetWords = ["headset", "headphone", "airpods", "earpods", "ヘッドセット", "ヘッドフォン", "ヘッドホン"]

    /// Whether a device is a headset by its transport (`bluetooth`: Bluetooth or Bluetooth LE) or its name.
    public static func isHeadset(name: String, bluetooth: Bool) -> Bool {
        if bluetooth { return true }
        let name = name.lowercased()
        return headsetWords.contains { name.contains($0) }
    }

    /// The device to listen to (its UID), nil for the system's input. A device chosen in Settings that is not
    /// connected (unplugged, out of range) counts as automatic until it comes back.
    public static func choose(_ setting: String, devices: [Device]) -> String? {
        if setting == systemDefault { return nil }
        if isDevice(setting), devices.contains(where: { $0.uid == setting }) { return setting }
        return devices.first(where: \.isHeadset)?.uid
    }

    /// The device `choose` picks, nil for the system's input.
    public static func chosen(_ setting: String, devices: [Device]) -> Device? {
        choose(setting, devices: devices).flatMap { uid in devices.first { $0.uid == uid } }
    }
}
