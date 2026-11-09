import Foundation
import Darwin
import CmdsCore
import os

struct WorkspaceMetadata: Sendable, Equatable {
    var workingDirectory: String?
    var gitBranch: String?
    var ports: [Int]
}

private let metadataLog = Logger(subsystem: "tokyo.n-n.cmds", category: "metadata")

/// Periodically refreshes git branches, listening ports and CPU/memory (per workspace and machine-wide)
/// on a background queue. One process scan feeds both ports and usage.
@MainActor
final class MetadataMonitor {
    private let controller: AppController
    private let scanner: ProcessScanner
    private let systemSampler = SystemSampler()
    private let codexWatcher = CodexSessionWatcher()
    private let queue = DispatchQueue(label: "cmds.metadata", qos: .utility)
    private var timer: Timer?
    private var scanning = false

    init(controller: AppController) {
        self.controller = controller
        scanner = ProcessScanner(socketPath: controller.socketPath)
    }

    func start(interval: TimeInterval = 2) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 0.5
        refresh()
        // CPU figures need two samples; take the second one soon rather than a full interval later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !scanning else { return }
        // Runs without workspaces too: the sidebar footer shows machine-wide usage regardless.
        // Remote workspaces (focused SSH pane): their cwd is on the server, never look it up here.
        let directories = Dictionary(uniqueKeysWithValues: controller.workspaces.map {
            ($0.id, $0.isRemote ? nil : $0.workingDirectory)
        })
        // Each pane's pty foreground group identifies its tty, hence every process running in it.
        var foregroundGroups: [pid_t: String] = [:]
        var paneGroups: [pid_t: String] = [:]
        for workspace in controller.workspaces {
            for pane in workspace.panes.values {
                if let group = pane.terminal?.foregroundProcessGroupID {
                    foregroundGroups[group] = workspace.id
                    paneGroups[group] = pane.id
                }
            }
        }
        scanning = true
        let scanner = scanner
        let systemSampler = systemSampler
        let codexWatcher = codexWatcher
        queue.async { [weak self] in
            let started = DispatchTime.now().uptimeNanoseconds
            let scan = scanner.scan(foregroundGroups: foregroundGroups, paneGroups: paneGroups)
            let codex = codexWatcher.update(scan.codexProcesses)
            let system = systemSampler.sample()
            let scanned = DispatchTime.now().uptimeNanoseconds
            var result: [String: WorkspaceMetadata] = [:]
            for (id, cwd) in directories {
                result[id] = WorkspaceMetadata(workingDirectory: cwd, gitBranch: cwd.flatMap(GitInfo.branch(at:)),
                                               ports: scan.ports[id] ?? [])
            }
            let finished = DispatchTime.now().uptimeNanoseconds
            metadataLog.debug("""
                scan: \(scan.listedProcesses, privacy: .public) pids, \(scan.workspaceProcesses, privacy: .public) \
                in workspaces, processes+system \(Double(scanned - started) / 1e6, format: .fixed(precision: 2), privacy: .public) ms, \
                git \(Double(finished - scanned) / 1e6, format: .fixed(precision: 2), privacy: .public) ms
                """)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.scanning = false
                    self?.controller.applyMetadata(result)
                    self?.controller.applyAgentScan(codex)
                    self?.controller.scanClaudeLimits()
                    self?.controller.applyResourceUsage(scan.usage, system: system, processes: scan.processes)
                }
            }
        }
    }
}

/// One pass over the processes launched from cmds terminals.
struct ProcessScan: Sendable {
    /// Listening TCP ports per workspace.
    var ports: [String: [Int]] = [:]
    /// CPU/memory per workspace that has at least one live process.
    var usage: [String: ResourceUsage] = [:]
    var listedProcesses = 0
    var workspaceProcesses = 0
    /// Codex processes of our user (sessions in our panes and shared daemons), for `CodexSessionWatcher`.
    var codexProcesses: [CodexProcess] = []
    /// Every live process started from our terminals, also after its pane closed (`system.processes`, #193).
    var processes: [ScannedProcess] = []
}

/// Finds the processes running in this app's terminals and reports their TCP listening ports and CPU/memory
/// per workspace. Attribution (`ProcessAttributor`): `CMDS_WORKSPACE_ID` from the environment where macOS
/// shows it (`KERN_PROCARGS2`, cached per pid + start time), else the pane tty found through each pane's
/// foreground process group, else the nearest attributed ancestor. Sockets come from `proc_pidfdinfo`, usage
/// from `proc_pid_rusage` (turned into percentages by `ProcessUsageAccountant`). Not thread-safe: use one queue.
final class ProcessScanner: @unchecked Sendable {
    /// A process across pid reuse: pid + start time (µs since 1970).
    private typealias ProcessKey = ProcessOrigins.Key

    /// What `KERN_PROCARGS2` says about a process (read once per process lifetime).
    private struct ProcessFacts {
        var environment: EnvironmentTag
        /// `CMDS_PANE_ID` when `environment` is one of our workspaces.
        var paneID: String?
        /// Codex processes only.
        var codexRole: AgentProcessClassifier.CodexRole?
        /// Executable and arguments (`ScannedProcess.command`), one character longer than `ProcessEntry.maxCommandLength`
        /// at most so that `ProcessList.build` still sees it was cut.
        var command: String?
    }

    /// One of our user's processes in this scan (`ScannedProcess`, pane attribution).
    private struct ProcessDetail {
        var start: UInt64
        var name: String
        var facts: ProcessFacts
    }

    /// Arguments read for `AgentProcessClassifier` (the default of `processArguments`).
    private static let classifiedArguments = 6
    /// Arguments read for `ProcessFacts.command`.
    private static let commandArguments = 32

    private var environmentByProcess: [ProcessKey: ProcessFacts] = [:]
    /// Where each process was first seen (#193): detached processes keep their pane after it closed.
    private var origins = ProcessOrigins()
    private var argumentBuffer = [UInt8]()
    private let uid = getuid()
    private let ownPID = getpid()
    /// `CMDS_SOCKET_PATH` given to our terminals. Other instances (a dev build next to the installed app)
    /// use their own socket, so processes carrying a different one are not ours.
    private let socketPath: String
    private var attributor = ProcessAttributor(ownPID: getpid())
    private var accountant = ProcessUsageAccountant(cpuCount: ProcessInfo.processInfo.activeProcessorCount)
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// - Parameters:
    ///   - foregroundGroups: foreground process group of each terminal pane's pty → workspace ID.
    ///   - paneGroups: the same groups → pane ID (to place agent processes in panes).
    func scan(foregroundGroups: [pid_t: String], paneGroups: [pid_t: String] = [:]) -> ProcessScan {
        let pids = allPIDs()
        var identities: [ProcessIdentity] = []
        identities.reserveCapacity(pids.count)
        var seen = Set<ProcessKey>()
        var codexCandidates: [(pid: pid_t, start: UInt64, tty: UInt32?, facts: ProcessFacts)] = []
        var paneByTTY: [UInt32: String] = [:]
        var details: [pid_t: ProcessDetail] = [:]
        for pid in pids {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            let ownUser = info.pbi_uid == uid && pid != ownPID
            var environment = EnvironmentTag.unknown
            let hasTTY = info.e_tdev != UInt32.max && info.e_tdev != 0 // NODEV: no controlling terminal
            if hasTTY, let pane = paneGroups[pid_t(bitPattern: info.e_tpgid)] { paneByTTY[info.e_tdev] = pane }
            if ownUser {
                let start = info.startMicroseconds
                let key = ProcessKey(pid: pid, start: start)
                seen.insert(key)
                let facts: ProcessFacts
                if let cached = environmentByProcess[key] {
                    facts = cached
                } else {
                    facts = processFacts(pid: pid)
                    environmentByProcess[key] = facts
                }
                environment = facts.environment
                details[pid] = ProcessDetail(start: start, name: processName(info), facts: facts)
                if facts.codexRole != nil { codexCandidates.append((pid, start, hasTTY ? info.e_tdev : nil, facts)) }
            }
            identities.append(ProcessIdentity(pid: pid, parentPID: pid_t(bitPattern: info.pbi_ppid),
                                              tty: hasTTY ? info.e_tdev : nil,
                                              ttyForegroundGroup: hasTTY ? pid_t(bitPattern: info.e_tpgid) : nil,
                                              isOwnUser: ownUser, environment: environment))
        }
        environmentByProcess = environmentByProcess.filter { seen.contains($0.key) }
        let knownPanes = Set(paneGroups.values)
        var codexProcesses: [CodexProcess] = []
        for candidate in codexCandidates {
            guard let role = candidate.facts.codexRole, role != .utility else { continue }
            var pane = candidate.facts.paneID.flatMap { knownPanes.contains($0) ? $0 : nil }
            if pane == nil, candidate.facts.environment != .foreign { pane = candidate.tty.flatMap { paneByTTY[$0] } }
            if role == .session && pane == nil { continue } // a session in another terminal app or instance
            codexProcesses.append(CodexProcess(
                pid: candidate.pid, started: Date(timeIntervalSince1970: Double(candidate.start) / 1_000_000),
                paneID: role == .session ? pane : nil, isService: role == .service,
                cwd: role == .session ? currentDirectory(pid: candidate.pid) : nil,
                rolloutFiles: rolloutFiles(pid: candidate.pid)))
        }

        let workspaces = attributor.attribute(identities, foregroundGroups: foregroundGroups)
        let panes = attributePanes(identities, details: details, paneByTTY: paneByTTY)
        var ports: [String: Set<Int>] = [:]
        var samples: [ProcessUsageSample] = []
        var sampled: [pid_t: ProcessOrigins.Origin] = [:]
        for identity in identities {
            // The origin sticks (#193): a process whose pane closed stays in its workspace, as a leftover.
            var origin: ProcessOrigins.Origin?
            if let detail = details[identity.pid] {
                origin = origins.resolve(ProcessKey(pid: identity.pid, start: detail.start),
                                         workspace: workspaces[identity.pid], pane: panes[identity.pid])
            }
            guard let workspace = origin?.workspace ?? workspaces[identity.pid] else { continue }
            if let sample = usageSample(pid: identity.pid, parentPID: identity.parentPID, workspace: workspace) {
                samples.append(sample)
                if let origin { sampled[identity.pid] = origin }
            }
            let listening = listeningPorts(pid: identity.pid)
            if !listening.isEmpty { ports[workspace, default: []].formUnion(listening) }
        }
        origins.keep(only: seen)
        // Listed after every sample was read: a sampled process missing here was reaped during the scan.
        let alive = Set(allPIDs())
        let usage = accountant.update(samples: samples, alivePIDs: alive, now: nanoseconds(mach_absolute_time()))
        let processes = samples.compactMap { sample -> ScannedProcess? in
            guard alive.contains(sample.pid), let origin = sampled[sample.pid], let detail = details[sample.pid] else { return nil }
            return ScannedProcess(pid: sample.pid, startMicroseconds: detail.start, name: detail.name,
                                  command: detail.facts.command, workspace: origin.workspace, pane: origin.pane,
                                  memoryBytes: sample.memoryBytes, cpuPercent: accountant.processCPUPercent[sample.pid])
        }
        return ProcessScan(ports: ports.mapValues { $0.sorted() }, usage: usage,
                           listedProcesses: pids.count, workspaceProcesses: samples.count,
                           codexProcesses: codexProcesses, processes: processes)
    }

    /// Pane of each of our user's processes: its `CMDS_PANE_ID`, else the pane of its terminal, else its nearest
    /// ancestor's.
    private func attributePanes(_ identities: [ProcessIdentity],
                                details: [pid_t: ProcessDetail],
                                paneByTTY: [UInt32: String]) -> [pid_t: String] {
        var direct: [pid_t: String] = [:]
        var parents: [pid_t: pid_t] = [:]
        for identity in identities where identity.isOwnUser {
            parents[identity.pid] = identity.parentPID
            if let pane = details[identity.pid]?.facts.paneID ?? identity.tty.flatMap({ paneByTTY[$0] }) {
                direct[identity.pid] = pane
            }
        }
        var result = direct
        for pid in parents.keys where direct[pid] == nil {
            var parent = parents[pid] ?? 0
            var hops = 0
            while hops < 64, parent > 1, parent != ownPID {
                if let pane = direct[parent] {
                    result[pid] = pane
                    break
                }
                guard let next = parents[parent] else { break }
                parent = next
                hops += 1
            }
        }
        return result
    }

    /// The process's name as Activity Monitor shows it (`pbi_name`, else the 16-character `pbi_comm`).
    private func processName(_ info: proc_bsdinfo) -> String {
        let name = cString(info.pbi_name)
        return name.isEmpty ? cString(info.pbi_comm) : name
    }

    /// A NUL-terminated string in one of the fixed-size char arrays of the `proc_*info` structs.
    private func cString<Chars>(_ chars: Chars) -> String {
        var chars = chars
        return withUnsafeBytes(of: &chars) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    private func processFacts(pid: pid_t) -> ProcessFacts {
        guard let parsed = processArguments(pid: pid, names: [CmdsEnv.workspaceID, CmdsEnv.socketPath, CmdsEnv.paneID],
                                            maxArguments: Self.commandArguments) else {
            return ProcessFacts(environment: .unknown)
        }
        let values = parsed.environment
        var facts = ProcessFacts(environment: .unknown)
        if let socket = values[CmdsEnv.socketPath], socket != socketPath {
            facts.environment = .foreign
        } else if let workspace = values[CmdsEnv.workspaceID], !workspace.isEmpty {
            facts.environment = .workspace(workspace)
            facts.paneID = values[CmdsEnv.paneID].flatMap { $0.isEmpty ? nil : $0 }
        }
        let arguments = Array(parsed.arguments.prefix(Self.classifiedArguments))
        if AgentProcessClassifier.agent(executablePath: parsed.executable, arguments: arguments) == .codex {
            facts.codexRole = AgentProcessClassifier.codexRole(arguments: arguments)
        }
        let command = parsed.arguments.isEmpty ? parsed.executable : parsed.arguments.joined(separator: " ")
        if !command.isEmpty { facts.command = String(command.prefix(ProcessEntry.maxCommandLength + 1)) }
        return facts
    }

    /// Working directory of a process (`PROC_PIDVNODEPATHINFO`).
    private func currentDirectory(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = cString(info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    /// Codex session files (`rollout-*.jsonl`) the process has open. Only paths are read, never contents.
    private func rolloutFiles(pid: pid_t) -> [String] {
        var result: [String] = []
        for fd in fileDescriptors(pid: pid) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = cString(info.pvip.vip_path)
            if CodexRollout.isRolloutPath(path), !result.contains(path) { result.append(path) }
        }
        return result
    }

    private func fileDescriptors(pid: pid_t) -> [proc_fdinfo] {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufferSize) / stride + 8)
        let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard used > 0 else { return [] }
        return Array(fds.prefix(Int(used) / stride))
    }

    private func usageSample(pid: pid_t, parentPID: pid_t, workspace: String) -> ProcessUsageSample? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        // CPU times and the start stamp are mach absolute time (not ns on Apple Silicon).
        return ProcessUsageSample(pid: pid, parentPID: parentPID,
                                  startTime: nanoseconds(usage.ri_proc_start_abstime),
                                  group: workspace,
                                  cpuTime: nanoseconds(usage.ri_user_time &+ usage.ri_system_time),
                                  childCPUTime: nanoseconds(usage.ri_child_user_time &+ usage.ri_child_system_time),
                                  memoryBytes: usage.ri_phys_footprint)
    }

    private func nanoseconds(_ ticks: UInt64) -> UInt64 {
        MachTime.nanoseconds(ticks, numer: timebase.numer, denom: timebase.denom)
    }

    private func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return count > 0 ? Array(pids.prefix(Int(count))) : []
    }

    /// Executable path, first arguments and the given variables of the process's initial environment
    /// (macOS hides the environment of Apple platform binaries).
    private func processArguments(pid: pid_t, names: [String],
                                  maxArguments: Int = ProcessScanner.classifiedArguments) -> (executable: String, arguments: [String], environment: [String: String])? {
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
        return argumentBuffer.withUnsafeBytes { raw in
            ProcessArguments.parse(UnsafeRawBufferPointer(rebasing: raw[0..<size]), maxArguments: maxArguments,
                                   environmentNames: names)
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

extension proc_bsdinfo {
    /// Start time in microseconds since 1970 (`pbi_start_tvsec * 1e6 + pbi_start_tvusec`): with the pid it identifies
    /// a process across pid reuse.
    var startMicroseconds: UInt64 { pbi_start_tvsec &* 1_000_000 &+ pbi_start_tvusec }
}
