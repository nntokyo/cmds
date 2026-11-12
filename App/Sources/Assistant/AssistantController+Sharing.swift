import AppKit
import CmdsCore
import os

private let sharingLog = Logger(subsystem: "tokyo.n-n.cmds", category: "assistant")

/// Sharing the microphone (#278): while another app records (a call) the assistant pauses by itself, silently, and
/// listens again when that has ended. The rules are `AssistantMicrophoneShare`; Core Audio says who records
/// (`AssistantAudioDevices.processes`), checked on the assistant's clock.
@available(macOS 26.0, *)
extension AssistantController {
    /// Who records now and what to do about it (`tick`). Off in Settings: as if nobody recorded, so a pause of its
    /// own ends. Text-only (`debug.assistant`) without the microphone: only the apps a test pretends record.
    func shareMicrophone() {
        guard isOn else { return }
        let recorders: [AssistantMicrophoneShare.Process]
        if let pretended = overrides.recorders {
            recorders = pretended.enumerated().map { .init(pid: Int32(-1 - $0.offset), bundleID: $0.element, recording: true) }
        } else if usesMicrophone, settings.assistantShareMicrophone {
            recorders = AssistantMicrophoneShare.recorders(AssistantAudioDevices.processes(), own: getpid())
        } else {
            recorders = []
        }
        switch microphoneShare.update(recorders: recorders, listening: !isPaused, now: Date()) {
        case .pause(let pid)?:
            let app = Self.appName(pid: pid, recorders: recorders)
            sharingLog.info("assistant paused: \(app, privacy: .public) records")
            recorderName = app
            stopListening()
            refresh()
        case .resume?:
            sharingLog.info("assistant listens again: no other app records")
            listenAgain()
        case nil:
            break
        }
    }

    /// The name of the app that records, for the menu bar: a helper's app (Chrome's `….helper` records for Meet in
    /// Chrome), else "Another app" (WebKit's media process, a daemon).
    private static func appName(pid: Int32, recorders: [AssistantMicrophoneShare.Process]) -> String {
        let bundleID = recorders.first { $0.pid == pid }?.bundleID ?? ""
        for candidate in [bundleID, AssistantMicrophoneShare.appBundleID(ofHelper: bundleID)] where !candidate.isEmpty {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: candidate).first(where: { $0.activationPolicy == .regular }),
               let name = app.localizedName {
                return name
            }
        }
        return String(localized: "Another app", comment: "assistant: an app records")
    }
}
