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
    /// listening too) and the system's own listeners (Siri, Sound Recognition) by bundle ID prefix.
    static let ignoredPrefixes = ["tokyo.n-n.cmds", "com.apple.CoreSpeech", "com.apple.corespeechd",
                                  "com.apple.assistantd", "com.apple.accessibility.heard"]

    /// The PID of the app the assistant stopped listening for; nil when it did not stop by itself.
    public private(set) var pausedFor: Int32?
    /// The user had it listen again during another app's recording: not stopped again until that has ended.
    public private(set) var overridden = false
    private var quietSince: Date?

    public init() {}

    /// The processes other than this one (`own` PID) that record and count.
    public static func recorders(_ processes: [Process], own: Int32) -> [Process] {
        processes.filter { process in
            process.recording && process.pid != own && !ignoredPrefixes.contains { process.bundleID.hasPrefix($0) }
        }
    }

    /// The app a helper process belongs to by its bundle ID (`com.google.Chrome.helper` → `com.google.Chrome`); the
    /// ID itself when it is no helper's.
    public static func appBundleID(ofHelper bundleID: String) -> String {
        for suffix in [".helper", ".Helper"] {
            if let range = bundleID.range(of: suffix) { return String(bundleID[..<range.lowerBound]) }
        }
        return bundleID
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

    /// The user paused, or the assistant was turned off: it is the user's pause now, not resumed by itself.
    public mutating func userPaused() {
        pausedFor = nil
        quietSince = nil
        overridden = false
    }
}
