import Foundation
import CmdsCore

/// `app.doctor` / `cmds doctor` (#454): gathers what `Doctor` checks. Read only; no file is written.
extension AppController {
    /// With the panes whose Claude Code session still holds CronCreate jobs (transcripts read off the main thread).
    func doctorReportWithSessionJobs() async -> DoctorReport {
        let sessions: [(pane: String, session: AgentSession)] = workspaces.flatMap(\.orderedPanes).compactMap { pane in
            guard let session = pane.agentSession ?? pane.resumeOffer, session.agent == .claude, session.host == nil else { return nil }
            return (pane.id, session)
        }
        let found = await Task.detached(priority: .utility) { () -> [(pane: String, jobs: [ResumeNote.Job])] in
            sessions.map { entry in
                let path = ClaudeTurnState.transcriptPath(sessionID: entry.session.sessionID, configDir: entry.session.configDir)
                return (entry.pane, path.map { ResumeNote.jobs(transcriptLines: ResumeNote.jobLines(path: $0), now: Date()) } ?? [])
            }
        }.value
        // A job counts until a schedule types the same prompt into the same pane.
        let moved = Set(scheduleRunner.schedules.compactMap { schedule -> String? in
            guard case .sendText(let send) = schedule.action, send.to == .agent,
                  let pane = scheduleRunner.entry(schedule).targetPane else { return nil }
            return pane + "\u{1}" + send.text
        })
        var counts: [String: Int] = [:]
        for entry in found {
            counts[entry.pane] = entry.jobs.filter { job in
                guard case .cron = job.kind else { return false }
                return !moved.contains(entry.pane + "\u{1}" + job.prompt)
            }.count
        }
        return doctorReport(sessionJobs: counts)
    }

    func doctorReport(now: Date = Date(), sessionJobs: [String: Int] = [:]) -> DoctorReport {
        let info = Bundle.main.infoDictionary ?? [:]
        // The bundle on disk now: a newer copy may have replaced the one that started.
        let disk = NSDictionary(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist"))
        let runner = scheduleRunner
        let weekAgo = now.addingTimeInterval(-7 * 86400)
        let bluetooth = SyncBluetoothPeripheral.shared
        let report = bluetooth.report
        let snapshot = DoctorSnapshot(
            runningVersion: info["CFBundleShortVersionString"] as? String ?? "0",
            runningBuild: info["CFBundleVersion"] as? String ?? "0",
            diskVersion: disk?["CFBundleShortVersionString"] as? String,
            diskBuild: disk?["CFBundleVersion"] as? String,
            updateOnQuit: Updater.shared.readyOnQuit,
            resumeMode: AgentResumeSettings.mode.rawValue,
            loginItem: LoginItem.state,
            schedulesReadOnly: runner.readOnlyReason?.english,
            schedulesMovedAside: runner.movedAside.map(\.lastPathComponent),
            scheduleProblems: runner.schedules.compactMap { schedule in
                runner.problem(of: schedule).map { "\(schedule.name): \($0.english)" }
            },
            schedulesDropped: runner.trash.deleted.filter { $0.reason == .dropped && $0.deletedAt >= weekAgo }.count,
            recentHangs: Self.recentHangs(now: now),
            memoryPressure: systemSample?.stats.pressure ?? .unknown,
            bluetoothStatus: report.managerState == "off" ? nil : report.status,
            bluetoothFailures: bluetooth.consecutiveFailures,
            sessionJobs: sessionJobs)
        return Doctor.report(snapshot)
    }

    /// Hang samples (`hangs/*.txt`) written in the last 24 h, newest first.
    private static func recentHangs(now: Date) -> [String] {
        let directory = CmdsEnv.supportDirectoryURL().appendingPathComponent(HangWatchdogPolicy.directoryName, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.compactMap { url -> (String, Date)? in
            guard url.pathExtension == "txt",
                  let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(date) <= 86400 else { return nil }
            return (url.lastPathComponent, date)
        }.sorted { $0.1 > $1.1 }.map(\.0)
    }
}
