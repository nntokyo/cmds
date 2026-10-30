import Foundation
import Observation

/// Which paths `FallbackTransport` may use. Anything but `.auto` exists for testing on a device
/// (docs/internals/testing.md "Testing sync on a device"): e.g. `.bluetooth` tests the Bluetooth path while Wi‑Fi stays on for
/// `devicectl`. Every mode keeps the same pinned TLS check; forcing a path never relaxes it.
enum TransportMode: String, CaseIterable {
    case auto, network, bluetooth, ssh

    static let defaultsKey = "cmdsTransport"

    /// The mode in effect. Debug builds: the debug menu's choice in this run, else the launch argument
    /// `-cmdsTransport <mode>` (argument domain of `UserDefaults`), else the menu's stored choice.
    /// Release builds: always `.auto` (the argument is ignored).
    static var current: TransportMode {
        #if DEBUG
        if let chosen = chosenInMenu { return chosen }
        return UserDefaults.standard.string(forKey: defaultsKey).flatMap(TransportMode.init(rawValue:)) ?? .auto
        #else
        return .auto
        #endif
    }

    #if DEBUG
    /// Set from the debug menu: wins over the launch argument for the rest of this run (main thread only).
    private static var chosenInMenu: TransportMode?

    /// Debug menu. Also stored, so it applies to later launches without the argument.
    static func set(_ mode: TransportMode) {
        chosenInMenu = mode
        UserDefaults.standard.set(mode.rawValue, forKey: defaultsKey)
    }
    #endif
}

/// What the current connection attempt did, per path ("bluetooth: scanning", "network: TLS ok", the error
/// text…), for the status badge's accessibility value and the debug diagnostics row, so a UI test driver can
/// tell which path is used and where it stopped. Never holds tokens, keys or codes.
/// Main thread only (`@unchecked Sendable` for the shared instance).
@Observable
final class ConnectionDiagnostics: @unchecked Sendable {
    static let shared = ConnectionDiagnostics()

    private(set) var mode: TransportMode = .auto
    /// Latest stage per path in the current attempt.
    private(set) var stages: [SyncLinkPath: String] = [:]
    /// Path of the live connection.
    private(set) var activePath: SyncLinkPath?
    /// Latest error of any attempt (kept across attempts until a connection is up).
    private(set) var lastError: String?

    /// A new connection attempt in `mode`.
    func begin(mode: TransportMode) {
        self.mode = mode
        stages = [:]
        activePath = nil
    }

    func stage(_ path: SyncLinkPath, _ text: String) {
        stages[path] = text
    }

    func failed(_ path: SyncLinkPath?, _ reason: String) {
        let text = Self.oneLine(reason)
        if let path { stages[path] = "error: " + text }
        lastError = (path.map { $0.key + ": " } ?? "") + text
    }

    func connected(_ path: SyncLinkPath?) {
        activePath = path
        if let path { stages[path] = "welcome" }
        lastError = nil
    }

    func ended() {
        activePath = nil
    }

    /// `mode=bluetooth path=bluetooth | bluetooth: welcome | error: …`
    var summary: String {
        var parts = ["mode=\(mode.rawValue) path=\(activePath?.key ?? "none")"]
        for path in [SyncLinkPath.network, .bluetooth, .ssh] {
            if let stage = stages[path] { parts.append("\(path.key): \(stage)") }
        }
        if let lastError { parts.append("lastError: \(lastError)") }
        return parts.joined(separator: " | ")
    }

    private static func oneLine(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " / ")
        return flat.count > 160 ? String(flat.prefix(159)) + "…" : flat
    }
}

extension SyncLinkPath {
    /// Stable, unlocalized name (diagnostics).
    var key: String {
        switch self {
        case .network: return "network"
        case .bluetooth: return "bluetooth"
        case .ssh: return "ssh"
        }
    }
}
