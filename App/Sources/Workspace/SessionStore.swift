import Foundation
import CmdsCore

/// Persisted window contents: workspaces with their layout and per-pane cwd/url.
/// Pane/workspace IDs are not persisted; they are reassigned on launch.
struct SessionState: Codable {
    indirect enum Node: Codable {
        case terminal(cwd: String?)
        case browser(url: String?)
        /// Preview pane (file path; `format` = forced rendering such as `diff`). Added later: older sessions lack it.
        case preview(path: String, format: String?)
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
        /// Agent sessions remembered per terminal pane (docs/AGENTS.md "Resuming sessions"). Added later: older
        /// sessions lack it; records that cannot be decoded are dropped instead of failing the whole file.
        var agentSessions: [PaneAgentSession]? = nil
    }

    /// The agent session of the pane at `paneIndex` (reading order of `layout`).
    struct PaneAgentSession: Codable {
        var paneIndex: Int
        var session: AgentSession
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

extension SessionState.WorkspaceState {
    private enum CodingKeys: String, CodingKey {
        case title, workingDirectory, layout, focusedPaneIndex, agentSessions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        layout = try c.decode(SessionState.Node.self, forKey: .layout)
        focusedPaneIndex = try c.decodeIfPresent(Int.self, forKey: .focusedPaneIndex)
        let lossy = try? c.decodeIfPresent([Lossy<SessionState.PaneAgentSession>].self, forKey: .agentSessions)
        let sessions = lossy?.compactMap(\.value) ?? []
        agentSessions = sessions.isEmpty ? nil : sessions
    }
}

/// Decodes an element or nil, so one bad element does not fail its array.
private struct Lossy<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}
