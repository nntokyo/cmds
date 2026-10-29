import Foundation

/// What a process's own environment says about it (`KERN_PROCARGS2`).
public enum EnvironmentTag: Equatable, Sendable {
    /// `CMDS_WORKSPACE_ID` of this app instance.
    case workspace(String)
    /// Started from another cmds instance's terminal (different `CMDS_SOCKET_PATH`): never ours.
    case foreign
    /// No `CMDS_*` visible. macOS hides the environment of Apple platform binaries (`/bin/zsh`, `make`,
    /// `git`, …), so this is common and says nothing.
    case unknown
}

/// The per-process facts needed to attribute it (from `proc_bsdinfo`).
public struct ProcessIdentity: Equatable, Sendable {
    public var pid: Int32
    public var parentPID: Int32
    /// Controlling terminal device, nil without one.
    public var tty: UInt32?
    /// Foreground process group of that terminal.
    public var ttyForegroundGroup: Int32?
    /// Only processes of the app's user are attributed (others are still used to discover ttys).
    public var isOwnUser: Bool
    public var environment: EnvironmentTag

    public init(pid: Int32, parentPID: Int32, tty: UInt32? = nil, ttyForegroundGroup: Int32? = nil,
                isOwnUser: Bool = true, environment: EnvironmentTag = .unknown) {
        self.pid = pid
        self.parentPID = parentPID
        self.tty = tty
        self.ttyForegroundGroup = ttyForegroundGroup
        self.isOwnUser = isOwnUser
        self.environment = environment
    }
}

/// Decides which workspace each process belongs to, in order:
/// 1. its environment (`CMDS_WORKSPACE_ID`, visible for third-party binaries such as node or python);
/// 2. its controlling terminal: each pane's pty foreground process group (from libghostty) identifies the
///    pane's tty, so the shell and everything it runs there count, platform binaries included;
/// 3. its nearest attributed ancestor, for children that left the terminal (daemons, `setsid`, detached
///    dev-server workers).
/// tty → workspace mappings are remembered while the tty has processes, so a foreground group that changed
/// between reading it and scanning costs nothing.
public struct ProcessAttributor: Sendable {
    private var workspaceByTTY: [UInt32: String] = [:]
    private let ownPID: Int32

    public init(ownPID: Int32) {
        self.ownPID = ownPID
    }

    /// - Parameters:
    ///   - processes: every process on the system (any user).
    ///   - foregroundGroups: foreground process group of each terminal pane's pty → workspace ID.
    /// - Returns: workspace per attributed pid (own user only, never the app itself).
    public mutating func attribute(_ processes: [ProcessIdentity], foregroundGroups: [Int32: String]) -> [Int32: String] {
        let presentTTYs = Set(processes.compactMap(\.tty))
        workspaceByTTY = workspaceByTTY.filter { presentTTYs.contains($0.key) }

        var fresh = Set<UInt32>()
        for process in processes {
            guard let tty = process.tty, let group = process.ttyForegroundGroup,
                  let workspace = foregroundGroups[group] else { continue }
            workspaceByTTY[tty] = workspace
            fresh.insert(tty)
        }

        var result: [Int32: String] = [:]
        var byPID: [Int32: ProcessIdentity] = [:]
        for process in processes {
            byPID[process.pid] = process
            guard process.isOwnUser, process.pid != ownPID, case .workspace(let workspace) = process.environment else { continue }
            result[process.pid] = workspace
            if let tty = process.tty, !fresh.contains(tty) { workspaceByTTY[tty] = workspace }
        }

        var unresolved: [ProcessIdentity] = []
        for process in processes where process.isOwnUser && process.pid != ownPID
            && process.environment == .unknown {
            if let tty = process.tty, let workspace = workspaceByTTY[tty] {
                result[process.pid] = workspace
            } else {
                unresolved.append(process)
            }
        }

        for process in unresolved {
            var parent = process.parentPID
            var hops = 0
            while hops < 64, parent > 1, parent != ownPID, let ancestor = byPID[parent] {
                if let workspace = result[parent] {
                    result[process.pid] = workspace
                    break
                }
                if ancestor.environment == .foreign { break }
                parent = ancestor.parentPID
                hops += 1
            }
        }
        return result
    }
}
