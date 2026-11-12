import AVFoundation
import CmdsCore
import CoreAudio
import Foundation
import os

private let devicesLog = Logger(subsystem: "tokyo.n-n.cmds", category: "assistant")

/// The Mac's audio inputs from Core Audio (#270, Settings › Assistant › Microphone): their UIDs, names and whether
/// they are headsets, and a callback when they or the system's input change. Reading them needs no permission and
/// never opens a microphone. Also sets the input device of the listener's engine (`select`).
@MainActor
final class AssistantAudioDevices {
    /// Devices were connected or removed, or the system's input changed.
    var onChange: (() -> Void)?
    private var listening = false
    private let queue = DispatchQueue.main

    private static let watched: [AudioObjectPropertySelector] = [kAudioHardwarePropertyDevices,
                                                                  kAudioHardwarePropertyDefaultInputDevice]
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.onChange?() }
    }

    /// Starts telling `onChange` (idempotent).
    func watch() {
        guard !listening else { return }
        listening = true
        for selector in Self.watched {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
    }

    func unwatch() {
        guard listening else { return }
        listening = false
        for selector in Self.watched {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
    }

    /// The devices with an input, in Core Audio's order.
    static func inputs() -> [AssistantInputDevice.Device] {
        allDevices().compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = string(id, kAudioObjectPropertyName) ?? uid
            let transport = uint32(id, kAudioDevicePropertyTransportType)
            let bluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
            // Aggregate and virtual devices (voice processing's own, loopback drivers) are no microphone to choose.
            guard transport != kAudioDeviceTransportTypeAggregate, transport != kAudioDeviceTransportTypeVirtual else { return nil }
            return AssistantInputDevice.Device(uid: uid, name: name,
                                               isHeadset: AssistantInputDevice.isHeadset(name: name, bluetooth: bluetooth))
        }
    }

    /// The Core Audio ID of the device with `uid` (nil when it is not connected).
    private static func deviceID(uid: String) -> AudioDeviceID? {
        allDevices().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    /// Makes the device with `uid` the input of the engine's input node (before it starts); nothing when it is not
    /// connected.
    static func select(uid: String, on node: AVAudioInputNode) {
        guard let id = deviceID(uid: uid), let unit = node.audioUnit else { return }
        var device = id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { devicesLog.error("assistant microphone not chosen: \(status, privacy: .public)") }
    }

    /// The processes Core Audio knows and whether each records from an input now (#278: another app on a call).
    /// Reads no audio and needs no permission.
    static func processes() -> [AssistantMicrophoneShare.Process] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            var pid: pid_t = 0
            var pidAddress = Self.address(kAudioProcessPropertyPID)
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            AudioObjectGetPropertyData(id, &pidAddress, 0, nil, &pidSize, &pid)
            return AssistantMicrophoneShare.Process(pid: pid, bundleID: string(id, kAudioProcessPropertyBundleID) ?? "",
                                                    recording: uint32(id, kAudioProcessPropertyIsRunningInput) != 0)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func allDevices() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func uint32(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }
}
