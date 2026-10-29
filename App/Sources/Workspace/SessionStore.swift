import Foundation
import CmdsCore

/// Persisted window contents: workspaces with their layout and per-pane cwd/url.
/// Pane/workspace IDs are not persisted; they are reassigned on launch.
struct SessionState: Codable {
    indirect enum Node: Codable {
        case terminal(cwd: String?)
        case browser(url: String?)
        /// SSH pane: reconnected only when the user clicks Connect (never on launch).
        case ssh(host: String, remoteCwd: String?)
        case split(axis: SplitAxis, ratio: Double, first: Node, second: Node)
    }

    struct WorkspaceState: Codable {
        var title: String?
        var workingDirectory: String?
        var layout: Node
        /// Index of the focused pane in reading order.
        var focusedPaneIndex: Int?
    }

    var workspaces: [WorkspaceState]
    var selectedIndex: Int?
}

enum SessionStore {
    /// `~/Library/Application Support/cmds`, or `$CMDS_SUPPORT_DIR` for an isolated (test) instance.
    static var directory: URL { CmdsEnv.supportDirectoryURL() }

    static var fileURL: URL { directory.appendingPathComponent("session.json") }

    static func load() -> SessionState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }

    static func save(_ state: SessionState) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("cmds: failed to save session: \(error)")
        }
    }
}
