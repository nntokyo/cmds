import CmdsCore
import Foundation
import os

private let remoteLog = Logger(subsystem: "tokyo.n-n.cmds", category: "files-remote")

/// SFTP connections of files panes and transfers (docs/internals/files-sftp.md): one `ssh -s HOST sftp` per host,
/// shared by that host's panes and transfers, made on first use and closed when nothing has used it for
/// `idleTimeout`; a connection that dropped is made again on the next use. Every call that connects blocks its
/// thread, so it is only made from background queues and transfer threads, never the main thread.
final class RemoteConnections: @unchecked Sendable {
    static let shared = RemoteConnections()

    /// Seconds a connection stays open after its last use.
    static let idleTimeout: TimeInterval = 120
    /// How often idle connections are looked for.
    static let idleCheckInterval: TimeInterval = 30

    private let lock = NSLock()
    private var connections: [String: SSHFileConnection] = [:]
    private var lastUsed: [String: Date] = [:]
    /// One lock per host, so two panes opening the same host start one ssh, not two.
    private var connectLocks: [String: NSLock] = [:]
    private var timer: DispatchSourceTimer?
    /// Hosts a transfer is using (set by `TransferCenter`); their connections are not closed as idle.
    var busyHosts: @Sendable () -> Set<String> = { [] }

    /// The host's connection, connecting first if there is none (or it dropped). Throws `SSHConnectError` or
    /// `SFTPError`.
    func connection(host: String) throws -> SSHFileConnection {
        let hostLock = lockFor(host)
        hostLock.lock()
        defer { hostLock.unlock() }
        if let existing = existing(host), existing.isConnected {
            touch(host)
            return existing
        }
        remoteLog.notice("connecting to \(host, privacy: .public)")
        let connection = try SSHFileConnection(host: host, configFile: CmdsEnv.filesSSHConfig())
        connection.client.onDisconnect = { [weak self] reason in
            remoteLog.notice("\(host, privacy: .public) disconnected: \(reason, privacy: .public)")
            self?.dropped(host, connection)
        }
        lock.lock()
        connections[host] = connection
        lastUsed[host] = Date()
        lock.unlock()
        startTimer()
        removeLeftoverParts(host: host, connection: connection)
        return connection
    }

    /// A new connection: part files an earlier run left on this host (quit or crash mid-transfer) are removed in the
    /// background, so the pane's listing does not wait for it.
    private func removeLeftoverParts(host: String, connection: SSHFileConnection) {
        let journal = TransferCenter.partJournal
        guard !journal.leftovers(host: host).isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let removed = journal.clean(host: host, tree: SFTPFileTree(client: connection.client, home: connection.home))
            if removed > 0 { remoteLog.notice("removed \(removed) leftover part files on \(host, privacy: .public)") }
        }
    }

    /// The host's files as a `FileTree` (connects if needed).
    func tree(host: String) throws -> SFTPFileTree {
        let connection = try connection(host: host)
        return SFTPFileTree(client: connection.client, home: connection.home)
    }

    /// The host's files through the connection that is open now, or nil when there is none: never connects (a paired
    /// phone browsing a remote files pane, which must not start ssh). Counts as a use.
    func openTree(host: String) -> SFTPFileTree? {
        guard let connection = existing(host), connection.isConnected else { return nil }
        touch(host)
        return SFTPFileTree(client: connection.client, home: connection.home)
    }

    /// The tree a transfer location is on.
    func tree(for location: FileLocation) throws -> FileTree {
        guard let host = location.host else { return LocalFileTree() }
        return try tree(host: host)
    }

    /// Marks the host's connection as used now (running transfers keep it open through `busyHosts`).
    private func touch(_ host: String) {
        lock.lock()
        lastUsed[host] = Date()
        lock.unlock()
    }

    /// Closes every connection (app quit).
    func closeAll() {
        lock.lock()
        let all = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        all.forEach(Self.quietlyClose)
    }

    /// Closes the connection to `host` (Reconnect starts a fresh one).
    func close(_ host: String) {
        lock.lock()
        let connection = connections.removeValue(forKey: host)
        lock.unlock()
        connection.map(Self.quietlyClose)
    }

    /// Closes a connection we no longer want (not a drop: nothing is logged).
    private static func quietlyClose(_ connection: SSHFileConnection) {
        connection.client.onDisconnect = nil
        connection.close()
    }

    private func existing(_ host: String) -> SSHFileConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connections[host]
    }

    private func lockFor(_ host: String) -> NSLock {
        lock.lock()
        defer { lock.unlock() }
        if let hostLock = connectLocks[host] { return hostLock }
        let hostLock = NSLock()
        connectLocks[host] = hostLock
        return hostLock
    }

    private func dropped(_ host: String, _ connection: SSHFileConnection) {
        lock.lock()
        if connections[host] === connection { connections[host] = nil }
        lock.unlock()
        connection.close()
    }

    private func startTimer() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.idleCheckInterval, repeating: Self.idleCheckInterval)
        timer.setEventHandler { [weak self] in self?.closeIdle() }
        timer.resume()
        self.timer = timer
    }

    private func closeIdle() {
        let busy = busyHosts()
        let now = Date()
        lock.lock()
        var idle: [SSHFileConnection] = []
        for (host, connection) in connections where !busy.contains(host)
            && now.timeIntervalSince(lastUsed[host] ?? .distantPast) > Self.idleTimeout {
            idle.append(connection)
            connections[host] = nil
        }
        lock.unlock()
        for connection in idle {
            remoteLog.notice("closing idle connection to \(connection.host, privacy: .public)")
            Self.quietlyClose(connection)
        }
    }
}
