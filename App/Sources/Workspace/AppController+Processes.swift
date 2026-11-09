import AppKit
import CmdsCore
import Darwin
import UserNotifications

/// The processes started from cmds terminals (#193): `system.processes`, `system.kill_process`, the sidebar's top
/// processes and leftover row, and the "memory is short" notification. The scan is MetadataMonitor's; the rules are
/// in CmdsCore (ProcessList.swift).
extension AppController {
    /// This app's start, µs since 1970: processes older than it carry ids of an earlier run.
    static let launchMicroseconds: UInt64 = processStartMicroseconds(getpid()) ?? 0

    /// Start time of a process (µs since 1970), nil when there is no such process.
    nonisolated static func processStartMicroseconds(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
    }

    /// Result of `system.processes`.
    func processList(_ request: ProcessListRequest) -> ProcessList {
        var livePanes = Set<String>()
        for workspace in workspaces { livePanes.formUnion(workspace.panes.keys) }
        return ProcessList.build(scannedProcesses, request: request, livePanes: livePanes,
                                 liveWorkspaces: Set(workspaces.map(\.id)), appStarted: Self.launchMicroseconds)
    }

    /// Leftover processes (heaviest first) and their total memory, for the sidebar row.
    func leftoverProcesses() -> ProcessList {
        processList(ProcessListRequest(limit: ProcessListRequest.maxLimit, leftover: true))
    }

    /// `system.kill_process`: SIGTERM (SIGKILL with `force`) to a process the latest scan attributed to our terminals.
    @discardableResult
    func killProcess(_ request: ProcessKillRequest) throws -> ProcessKillResult {
        let process = try request.authorize(scanned: scannedProcesses,
                                            currentStart: Self.processStartMicroseconds(request.pid), ownPID: getpid())
        let signal = request.force ? SIGKILL : SIGTERM
        guard Darwin.kill(process.pid, signal) == 0 else {
            let reason = String(cString: strerror(errno))
            throw RPCError(code: 500, message: "could not stop \(process.pid): \(reason)")
        }
        return ProcessKillResult(pid: process.pid, signal: request.force ? "KILL" : "TERM", name: process.name)
    }

    /// Feeds the pressure reading to the alarm; posts the notification when it fires (Settings › General).
    func checkMemoryPressure(_ sample: SystemSample) {
        guard memoryAlarm.update(pressure: sample.stats.pressure, now: Date()),
              AppSettings.shared.memoryWarning else { return }
        let text = memoryWarningText(sample)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "cmds.memory.\(UUID().uuidString)",
                                                                     content: content, trigger: nil))
    }

    /// "Memory is short" / "Swap 3.9 GB in use. Heaviest: node (p3) 1.2 GB."
    func memoryWarningText(_ sample: SystemSample?) -> (title: String, body: String) {
        let title = String(localized: "Memory is short", comment: "notification title (memory pressure warning)")
        var parts: [String] = []
        if let swap = sample?.swapUsedBytes, swap > 0 {
            parts.append(String(localized: "Swap \(ResourceFormat.bytes(swap)) in use.", comment: "memory warning notification"))
        } else {
            parts.append(String(localized: "Memory pressure: \(sample?.stats.pressure.localizedName ?? "–")"))
        }
        if let top = processList(ProcessListRequest(limit: 1)).processes.first {
            let place = top.pane ?? top.workspace
            parts.append(String(localized: "Heaviest: \(top.name) (\(place)) \(ResourceFormat.bytes(top.memoryBytes)).",
                                comment: "memory warning notification: process name, pane id, memory"))
        }
        parts.append(String(localized: "Close what you do not need, or wait before starting another build.",
                            comment: "memory warning notification"))
        return (title, parts.joined(separator: " "))
    }

    /// Workspace tooltip: its top `count` processes, one line each (`node server.js  1.2 GB`).
    func topProcessLines(workspaceID: String, count: Int = 3) -> [String] {
        processList(ProcessListRequest(limit: count, workspace: workspaceID)).processes.map { process in
            let command = process.command.map { String($0.prefix(40)) } ?? process.name
            return "\(command)  \(ResourceFormat.bytes(process.memoryBytes))"
                + (process.isLeftover ? " " + String(localized: "(leftover)", comment: "process whose pane was closed") : "")
        }
    }
}
