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
        /// Files pane (folder; `showHidden`/`follow` only when on). Added later: older versions cannot read it.
        /// `host`: a folder on that SSH host, reconnected only when the user clicks Connect (added later; older
        /// versions open the path on the Mac, or the home folder).
        case files(path: String, showHidden: Bool?, follow: Bool?, host: String?)
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
        /// Agent sessions remembered per terminal pane (docs/guide/ai-agents.md "Resuming sessions"). Added later: older
        /// sessions lack it; records that cannot be decoded are dropped instead of failing the whole file.
        var agentSessions: [PaneAgentSession]? = nil
        /// Claude account of each terminal pane that has one (its shell gets the account's `CLAUDE_CONFIG_DIR` again).
        /// Added later; an account removed meanwhile is ignored.
        var paneAccounts: [PaneAccount]? = nil
        /// Schedule tag of each terminal pane that has one (`Pane.scheduleTag`). Added later (schedules phase 2): older
        /// versions ignore it and drop it when they save, so a schedule then finds no pane and skips its run.
        var paneTags: [PaneTag]? = nil
        /// The opener of each browser, preview or files pane opened from a terminal pane of the workspace (`Pane.openedBy`,
        /// #165). Added later: older sessions lack it, older versions ignore it.
        var paneOpeners: [PaneOpener]? = nil
        /// The worktree cmds created the workspace in (`Workspace.worktreePath`, #172). Added later: older sessions lack
        /// it, older versions ignore it.
        var worktree: String? = nil
    }

    /// The pane at `paneIndex` was opened from the terminal pane at `openerIndex` (reading order of `layout`).
    struct PaneOpener: Codable {
        var paneIndex: Int
        var openerIndex: Int
    }

    /// The schedule tag of the pane at `paneIndex` (reading order of `layout`).
    struct PaneTag: Codable {
        var paneIndex: Int
        var tag: String
    }

    /// The Claude account of the pane at `paneIndex` (reading order of `layout`).
    struct PaneAccount: Codable {
        var paneIndex: Int
        var account: String
    }

    /// The agent session of the pane at `paneIndex` (reading order of `layout`).
    struct PaneAgentSession: Codable {
        var paneIndex: Int
        var session: AgentSession
    }

    /// The tiled view (several workspaces side by side). Added later: older sessions lack it, older versions ignore it.
    struct TilingState: Codable {
        /// Tiling every workspace the sidebar shows; else `workspaceIndices`.
        var all: Bool
        var workspaceIndices: [Int]?
        /// The tile shown alone (⇧⌘↩).
        var zoomedIndex: Int?
        /// A dragged arrangement: rows of workspace indices, top to bottom. Added later; nil = automatic grid.
        var rows: [[Int]]? = nil
    }

    /// Divider positions remembered for one tiling set (indices into `workspaces`) and grid shape.
    struct TileLayoutState: Codable {
        var workspaceIndices: [Int]
        var shape: [Int]
        var ratios: TileRatios
    }

    var workspaces: [WorkspaceState]
    var selectedIndex: Int?
    var tiling: TilingState? = nil
    var tileLayouts: [TileLayoutState]? = nil
}

enum SessionStore {
    /// `~/Library/Application Support/cmds`, or `$CMDS_SUPPORT_DIR` for an isolated (test) instance.
    static var directory: URL { CmdsEnv.supportDirectoryURL() }

    static var fileURL: URL { directory.appendingPathComponent("session.json") }

    /// Set when an unreadable session file could not be moved aside: saving would overwrite it (#3).
    @MainActor private static var saveBlocked = false

    /// The saved session, or nil if there is none. An unreadable file is moved to `session.json.corrupt-<date>`
    /// (kept) and nil is returned, so the next save does not overwrite the user's workspaces (#3).
    @MainActor static func load() -> SessionState? {
        switch StoredFile.load(SessionState.self, from: fileURL) {
        case .missing:
            return nil
        case .loaded(let state):
            return state
        case .unreadable(let error, .success(let backup)):
            NSLog("cmds: could not read session (\(error)); moved it to \(backup.path)")
            return nil
        case .unreadable(let error, .failure(let moveError)):
            NSLog("cmds: could not read session (\(error)) or move it aside (\(moveError)); not saving this run")
            saveBlocked = true
            return nil
        }
    }

    @MainActor static func save(_ state: SessionState) {
        guard !saveBlocked else { return }
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
        case title, workingDirectory, layout, focusedPaneIndex, agentSessions, paneAccounts, paneTags, paneOpeners
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
        let accounts = (try? c.decodeIfPresent([Lossy<SessionState.PaneAccount>].self, forKey: .paneAccounts))?.compactMap(\.value) ?? []
        paneAccounts = accounts.isEmpty ? nil : accounts
        let tags = (try? c.decodeIfPresent([Lossy<SessionState.PaneTag>].self, forKey: .paneTags))?.compactMap(\.value) ?? []
        paneTags = tags.isEmpty ? nil : tags
        let openers = (try? c.decodeIfPresent([Lossy<SessionState.PaneOpener>].self, forKey: .paneOpeners))?.compactMap(\.value) ?? []
        paneOpeners = openers.isEmpty ? nil : openers
    }
}

/// Decodes an element or nil, so one bad element does not fail its array.
private struct Lossy<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}
