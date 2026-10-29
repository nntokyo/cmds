import Foundation
import Darwin
import CmdsCore

struct WorkspaceMetadata: Sendable, Equatable {
    var workingDirectory: String?
    var gitBranch: String?
    var ports: [Int]
}

/// Periodically refreshes git branches and listening ports for all workspaces on a background queue.
@MainActor
final class MetadataMonitor {
    private let controller: AppController
    private let scanner = PortScanner()
    private let queue = DispatchQueue(label: "cmds.metadata", qos: .utility)
    private var timer: Timer?
    private var scanning = false

    init(controller: AppController) {
        self.controller = controller
    }

    func start(interval: TimeInterval = 3) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 0.5
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !scanning else { return }
        let directories = Dictionary(uniqueKeysWithValues: controller.workspaces.map { ($0.id, $0.workingDirectory) })
        guard !directories.isEmpty else { return }
        scanning = true
        let scanner = scanner
        queue.async { [weak self] in
            let ports = scanner.listeningPorts()
            var result: [String: WorkspaceMetadata] = [:]
            for (id, cwd) in directories {
                result[id] = WorkspaceMetadata(workingDirectory: cwd, gitBranch: cwd.flatMap(GitInfo.branch(at:)),
                                               ports: ports[id] ?? [])
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.scanning = false
                    self?.controller.applyMetadata(result)
                }
            }
        }
    }
}

/// Finds TCP listening ports of processes launched from cmds terminals, keyed by `CMDS_WORKSPACE_ID`.
/// Process environments are read via `KERN_PROCARGS2` and cached per (pid, start time), so each scan
/// only inspects new processes; sockets come from `proc_pidfdinfo`. Not thread-safe: use one queue.
final class PortScanner: @unchecked Sendable {
    private struct ProcessKey: Hashable {
        var pid: pid_t
        var start: UInt64
    }

    /// nil value = process has no CMDS_WORKSPACE_ID.
    private var workspaceByProcess: [ProcessKey: String?] = [:]
    private var argumentBuffer = [UInt8]()
    private let uid = getuid()
    private let ownPID = getpid()

    func listeningPorts() -> [String: [Int]] {
        var seen = Set<ProcessKey>()
        var ports: [String: Set<Int>] = [:]
        for pid in allPIDs() where pid != ownPID {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == uid else { continue }
            let key = ProcessKey(pid: pid, start: info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec)
            seen.insert(key)
            let workspace: String?
            if let cached = workspaceByProcess[key] {
                workspace = cached
            } else {
                workspace = environmentValue(pid: pid, name: CmdsEnv.workspaceID)
                workspaceByProcess[key] = .some(workspace)
            }
            guard let workspace else { continue }
            let listening = listeningPorts(pid: pid)
            if !listening.isEmpty { ports[workspace, default: []].formUnion(listening) }
        }
        workspaceByProcess = workspaceByProcess.filter { seen.contains($0.key) }
        return ports.mapValues { $0.sorted() }
    }

    private func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return count > 0 ? Array(pids.prefix(Int(count))) : []
    }

    private func environmentValue(pid: pid_t, name: String) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        if argumentBuffer.isEmpty {
            var argMax: Int32 = 0
            var argMaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
            var length = MemoryLayout<Int32>.size
            sysctl(&argMaxMib, 2, &argMax, &length, nil, 0)
            argumentBuffer = [UInt8](repeating: 0, count: Int(max(argMax, 256 * 1024)))
        }
        var size = argumentBuffer.count
        let ok = argumentBuffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) } == 0
        guard ok, size > MemoryLayout<Int32>.size else { return nil }

        return argumentBuffer.withUnsafeBytes { raw -> String? in
            let bytes = raw.bindMemory(to: UInt8.self)
            let argc = Int(raw.loadUnaligned(as: Int32.self))
            var index = MemoryLayout<Int32>.size
            // Skip the executable path and its NUL padding.
            while index < size, bytes[index] != 0 { index += 1 }
            while index < size, bytes[index] == 0 { index += 1 }
            // Skip argv.
            var skipped = 0
            while index < size, skipped < argc {
                while index < size, bytes[index] != 0 { index += 1 }
                index += 1
                skipped += 1
            }
            let prefix = Array((name + "=").utf8)
            while index < size, bytes[index] != 0 {
                let start = index
                while index < size, bytes[index] != 0 { index += 1 }
                if index - start > prefix.count,
                   prefix.indices.allSatisfy({ bytes[start + $0] == prefix[$0] }) {
                    return String(decoding: UnsafeBufferPointer(rebasing: bytes[(start + prefix.count)..<index]), as: UTF8.self)
                }
                index += 1
            }
            return nil
        }
    }

    private func listeningPorts(pid: pid_t) -> Set<Int> {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufferSize) / stride + 8)
        let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard used > 0 else { return [] }

        var result = Set<Int>()
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
                  socket.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = socket.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if port > 0 { result.insert(port) }
        }
        return result
    }
}
