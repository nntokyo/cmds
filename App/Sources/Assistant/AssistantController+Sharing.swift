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
    /// own ends. Text-only (`debug.assistant`) without the microphone: only the apps a test pretends record, through
    /// the same rules (#295: the released app for a Debug build, the user's ignore list).
    func shareMicrophone() {
        guard isOn else { return }
        let recorders: [AssistantMicrophoneShare.Process]
        if let pretended = overrides.recorders {
            recorders = sharingRecorders(pretended.enumerated().map {
                .init(pid: Int32(-1 - $0.offset), bundleID: $0.element, recording: true)
            })
        } else if usesMicrophone, settings.assistantShareMicrophone {
            recorders = sharingRecorders(AssistantAudioDevices.processes())
        } else {
            recorders = []
        }
        switch microphoneShare.update(recorders: recorders, listening: !isPaused, now: Date()) {
        case .pause(let pid)?:
            let bundleID = recorders.first { $0.pid == pid }?.bundleID ?? ""
            let app = Self.recorderName(bundleID: bundleID)
            sharingLog.info("assistant paused: \(app, privacy: .public) records")
            recorderName = app
            recorderBundleID = bundleID
            stopListening()
            refresh()
        case .resume?:
            sharingLog.info("assistant listens again: no other app records")
            listenAgain()
        case nil:
            break
        }
    }

    /// The processes that count (`AssistantMicrophoneShare.recorders`): not this one, by this app's bundle ID (#295:
    /// a Debug build counts the released app), without the apps the user ignores.
    private func sharingRecorders(_ processes: [AssistantMicrophoneShare.Process]) -> [AssistantMicrophoneShare.Process] {
        AssistantMicrophoneShare.recorders(processes, own: getpid(), ownBundleID: Bundle.main.bundleIdentifier ?? "",
                                           ignored: Set(settings.assistantIgnoredRecorders))
    }

    /// Paused for the released app's assistant (#295, a Debug build): the menu bar says so, and offers no "Don't
    /// Pause for …" (only one of them answers).
    var pausedForCmds: Bool { pausedForBundleID == AssistantMicrophoneShare.cmdsBundleID }

    /// The app it paused for can be ignored (#295): it has a bundle ID, and is not the released app's assistant.
    var canIgnoreRecorder: Bool { !(pausedForBundleID ?? "").isEmpty && !pausedForCmds }

    /// "Don't Pause for …" (#295): the app it paused for (a helper's app) is added to the ignore list and it listens
    /// again at once; another app recording pauses it again on the next tick.
    func ignoreRecorder() {
        guard canIgnoreRecorder, let bundleID = pausedForBundleID else { return }
        let id = AssistantMicrophoneShare.ignoreID(for: bundleID)
        var ignored = settings.assistantIgnoredRecorders
        if !ignored.contains(id) {
            ignored.append(id)
            settings.assistantIgnoredRecorders = ignored
        }
        sharingLog.info("assistant ignores \(id, privacy: .public) recording")
        microphoneShare.recorderIgnored()
        listenAgain()
        refresh()
    }

    /// The name of the app that records, for the menu bar: cmds for the released app (#295), a helper's app
    /// (Chrome's `….helper` records for Meet in Chrome), else "Another app" (WebKit's media process, a daemon).
    private static func recorderName(bundleID: String) -> String {
        if bundleID == AssistantMicrophoneShare.cmdsBundleID { return "cmds" }
        return runningAppName(bundleID: bundleID) ?? String(localized: "Another app", comment: "assistant: an app records")
    }

    /// The name of a running app with this bundle ID or of the app a helper with it belongs to; nil when none runs.
    private static func runningAppName(bundleID: String) -> String? {
        for candidate in [bundleID, AssistantMicrophoneShare.appBundleID(ofHelper: bundleID)] where !candidate.isEmpty {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: candidate).first(where: { $0.activationPolicy == .regular }),
               let name = app.localizedName {
                return name
            }
        }
        return nil
    }

    /// The name of an ignored app for Settings and the menu bar (#295): running, else installed (Launch Services),
    /// else its bundle ID.
    static func ignoredAppName(bundleID: String) -> String {
        if let name = runningAppName(bundleID: bundleID) { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return bundleID
    }

    /// The app "Don't Pause for …" names (#295): as Settings will list it, so a recorder the menu calls "Another
    /// app" shows its bundle ID; nil when it cannot be ignored.
    var ignorableRecorderName: String? {
        guard canIgnoreRecorder, let bundleID = pausedForBundleID else { return nil }
        return Self.ignoredAppName(bundleID: AssistantMicrophoneShare.ignoreID(for: bundleID))
    }
}
