import Foundation

/// Sharing the microphone with other apps (#278): while another app records (a call in Zoom, FaceTime, Teams or a
/// browser, Voice Memos, dictation elsewhere) the assistant stops listening by itself, and listens again once that
/// has ended, unless the user paused it. Which processes record comes from Core Audio (the app); the rules are here.
public struct AssistantMicrophoneShare: Equatable, Sendable {
    /// A process Core Audio knows, as far as the rules need it.
    public struct Process: Equatable, Sendable {
        public var pid: Int32
        public var bundleID: String
        /// It records from an input now.
        public var recording: Bool

        public init(pid: Int32, bundleID: String, recording: Bool) {
            self.pid = pid
            self.bundleID = bundleID
            self.recording = recording
        }
    }

    public enum Change: Equatable, Sendable {
        /// Stop listening: the process with this PID records.
        case pause(pid: Int32)
        /// Listen again: nothing else has recorded for `resumeDelay`.
        case resume
    }

    /// How long nothing else must record before the assistant listens again (a call app reopening its input when
    /// the user switches microphones must not let it hear the call in between).
    public static let resumeDelay: TimeInterval = 2

    /// Processes that record all the time or are cmds: never a reason to stop. Other cmds instances (a test build
    /// listening too) and the system's own listeners (Siri, Sound Recognition) by bundle ID prefix; but a Debug build
    /// stops for the released app (`countsAsRecorder`, #295).
    static let ignoredPrefixes = [cmdsBundleID, "com.apple.CoreSpeech", "com.apple.corespeechd",
                                  "com.apple.assistantd", "com.apple.accessibility.heard"]

    /// The released app's bundle ID (#295). Its process records only for its assistant: recording means it listens.
    public static let cmdsBundleID = "tokyo.n-n.cmds"

    /// A Debug build ("cmds Dev", `tokyo.n-n.cmds.dev`) by its own bundle ID (#295).
    public static func isDebugBuild(_ ownBundleID: String) -> Bool {
        ownBundleID.hasPrefix(cmdsBundleID) && ownBundleID.hasSuffix(".dev")
    }

    /// The PID of the app the assistant stopped listening for; nil when it did not stop by itself.
    public private(set) var pausedFor: Int32?
    /// The user had it listen again during another app's recording: not stopped again until that has ended.
    public private(set) var overridden = false
    private var quietSince: Date?

    public init() {}

    /// The processes other than this one (`own` PID) that record and count. `ownBundleID`: this app's (#295: a Debug
    /// build stops while the released app's assistant listens, so only one of them answers; the released app never
    /// stops for a Debug build). `ignored`: the bundle IDs the user chose never to stop for ("Don't Pause for …"),
    /// matched as given and as a helper's app (`ignoreID(for:)`).
    public static func recorders(_ processes: [Process], own: Int32, ownBundleID: String,
                                 ignored: Set<String> = []) -> [Process] {
        processes.filter { process in
            process.recording && process.pid != own && countsAsRecorder(process.bundleID, ownBundleID: ownBundleID)
                && !ignored.contains(process.bundleID) && !ignored.contains(ignoreID(for: process.bundleID))
        }
    }

    /// Whether a process with this bundle ID recording is a reason to stop, before the user's ignore list (#295).
    static func countsAsRecorder(_ bundleID: String, ownBundleID: String) -> Bool {
        if bundleID == cmdsBundleID, isDebugBuild(ownBundleID) { return true }
        return !ignoredPrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// The ID "Don't Pause for …" keeps for a recorder (#295): its app's for a helper (Chrome's `….helper` records for
    /// Meet), so all of the app's helpers are ignored.
    public static func ignoreID(for bundleID: String) -> String {
        appBundleID(ofHelper: bundleID)
    }

    /// The app a helper process belongs to by its bundle ID (`com.google.Chrome.helper` → `com.google.Chrome`); the
    /// ID itself when it is no helper's.
    public static func appBundleID(ofHelper bundleID: String) -> String {
        guard let range = bundleID.range(of: ".helper", options: .caseInsensitive) else { return bundleID }
        return String(bundleID[..<range.lowerBound])
    }

    /// The assistant's clock: `recorders` now (`recorders(_:own:)`), `listening` whether it listens (on, not paused).
    /// Returns what to do, if anything.
    public mutating func update(recorders: [Process], listening: Bool, now: Date) -> Change? {
        if let first = recorders.first {
            quietSince = nil
            guard pausedFor == nil, !overridden, listening else { return nil }
            pausedFor = first.pid
            return .pause(pid: first.pid)
        }
        overridden = false
        guard pausedFor != nil else {
            quietSince = nil
            return nil
        }
        guard let quietSince else {
            self.quietSince = now
            return nil
        }
        guard now.timeIntervalSince(quietSince) >= Self.resumeDelay else { return nil }
        pausedFor = nil
        self.quietSince = nil
        return .resume
    }

    /// The user resumed listening (menu, shortcut): during another app's recording it stays on until that ends.
    public mutating func userResumed() {
        guard pausedFor != nil else { return }
        pausedFor = nil
        quietSince = nil
        overridden = true
    }

    /// The user chose never to stop for the app it stopped for (#295): it listens again now (the caller resumes), and
    /// the app no longer counts (`recorders(_:own:ownBundleID:ignored:)`). Another app recording stops it again.
    public mutating func recorderIgnored() {
        pausedFor = nil
        quietSince = nil
        overridden = false
    }

    /// The user paused, or the assistant was turned off: it is the user's pause now, not resumed by itself.
    public mutating func userPaused() {
        pausedFor = nil
        quietSince = nil
        overridden = false
    }
}
