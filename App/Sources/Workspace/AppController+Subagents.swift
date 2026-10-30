import AppKit
import CmdsCore

/// Show subagents (cmds › Settings… › Agents, View › Show Subagents).
enum SubagentDisplay: String, CaseIterable {
    case off
    /// Cards under each tile of the tiled view only (default).
    case tiled
    /// Also a strip under the single workspace.
    case everywhere

    var title: String {
        switch self {
        case .off: return String(localized: "Off", comment: "show subagents")
        case .tiled: return String(localized: "In Tiled View Only", comment: "show subagents")
        case .everywhere: return String(localized: "Everywhere", comment: "show subagents")
        }
    }
}

/// A subagent of a pane's agent, with what the app needs to follow it (never saved, never sent as is).
struct SubagentTrack {
    var info: SubagentInfo
    /// Local panes only: the subagent's transcript (shape-checked; see `SubagentTranscript.validatedPath`).
    var transcriptPath: String?
    /// Size and time the transcript was last read at / seen growing.
    var transcriptSize: UInt64 = 0
    var lastSeenAt: Date
    var metaLoaded = false
}

/// Claude Code subagents (docs/guide/ai-agents.md "Subagents"): `SubagentStart` / `SubagentStop` hooks add and finish
/// them; a 1 s timer follows the transcripts of running ones in local panes and drops finished / abandoned ones.
/// Activity ticks go to `subagentChanges` (cards only); adding or dropping one emits a pane change (sidebar count).
extension AppController {
    /// A finished subagent stays listed (dimmed) this long.
    static let subagentDoneLinger: TimeInterval = 20
    /// A running subagent with neither transcript growth nor hooks for this long is dropped (agent crashed, hook lost).
    static let subagentAbandonedAfter: TimeInterval = 15 * 60

    func handleSubagentHook(pane: Pane, agent: ClaudeHook.Subagent, now: Date = Date()) {
        // The transcript is read only for local panes (an SSH pane's path is on the server).
        let path = pane.ssh == nil ? agent.transcriptPath : nil
        if let index = pane.subagents.firstIndex(where: { $0.info.id == agent.agentID }) {
            var track = pane.subagents[index]
            if track.info.agentType == nil { track.info.agentType = agent.agentType }
            if track.transcriptPath == nil { track.transcriptPath = path }
            track.lastSeenAt = now
            if !agent.started, track.info.state == .running {
                track.info.state = .done
                track.info.endedAt = now
                track.info.elapsedSeconds = Int(now.timeIntervalSince(track.info.startedAt))
            }
            pane.subagents[index] = track
        } else {
            // A stop without a start (hook added mid-run, app restarted) is listed as done.
            let info = SubagentInfo(id: agent.agentID, workspace: pane.workspaceID, pane: pane.id,
                                    agentType: agent.agentType, state: agent.started ? .running : .done,
                                    startedAt: now, endedAt: agent.started ? nil : now)
            pane.subagents.append(SubagentTrack(info: info, transcriptPath: path, lastSeenAt: now))
        }
        refreshSubagentTranscripts(of: [pane], now: now) { [weak self] in
            self?.emit(.pane(workspaceID: pane.workspaceID, paneID: pane.id))
        }
        scheduleSubagentTimer()
    }

    /// The pane's agent ended (SessionEnd, process exit): its subagents go with it.
    func dropSubagents(of pane: Pane) {
        guard !pane.subagents.isEmpty else { return }
        pane.subagents.removeAll()
        emit(.pane(workspaceID: pane.workspaceID, paneID: pane.id))
    }

    /// `agent.subagents`: running and recently finished subagents, optionally of one pane / workspace.
    func subagentList(paneID: String? = nil, workspaceID: String? = nil) throws -> SubagentList {
        if let paneID, pane(id: paneID) == nil { throw RPCError.notFound("pane not found: \(paneID)") }
        if let workspaceID, workspace(id: workspaceID) == nil { throw RPCError.notFound("workspace not found: \(workspaceID)") }
        let now = Date()
        let list = workspaces.filter { workspaceID == nil || $0.id == workspaceID }.flatMap { workspace in
            workspace.orderedPanes.filter { paneID == nil || $0.id == paneID }.flatMap { pane in
                pane.subagents.map { Self.liveInfo($0.info, now: now) }
            }
        }
        return SubagentList(subagents: list)
    }

    /// `info` with `elapsedSeconds` up to now while running.
    static func liveInfo(_ info: SubagentInfo, now: Date) -> SubagentInfo {
        var info = info
        if info.state == .running { info.elapsedSeconds = max(0, Int(now.timeIntervalSince(info.startedAt))) }
        return info
    }

    private func scheduleSubagentTimer() {
        guard subagentTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.subagentTick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        subagentTimer = timer
    }

    private func subagentTick() {
        let now = Date()
        var dropped: [Pane] = []
        var panes: [Pane] = []
        for workspace in workspaces {
            for pane in workspace.panes.values where !pane.subagents.isEmpty {
                let before = pane.subagents.count
                pane.subagents.removeAll { track in
                    switch track.info.state {
                    case .done: return now.timeIntervalSince(track.info.endedAt ?? now) > Self.subagentDoneLinger
                    case .running: return now.timeIntervalSince(track.lastSeenAt) > Self.subagentAbandonedAfter
                    }
                }
                if pane.subagents.count != before { dropped.append(pane) }
                if !pane.subagents.isEmpty { panes.append(pane) }
            }
        }
        for pane in dropped { emit(.pane(workspaceID: pane.workspaceID, paneID: pane.id)) }
        if panes.isEmpty {
            subagentTimer?.invalidate()
            subagentTimer = nil
        }
        refreshSubagentTranscripts(of: panes, now: now) { [weak self] in self?.subagentSubject.send() }
    }

    /// Reads the transcripts that grew (off the main thread), then applies action / tokens / meta and calls `done`.
    private func refreshSubagentTranscripts(of panes: [Pane], now: Date, done: @escaping @MainActor () -> Void) {
        struct Job: Sendable { let paneID: String; let agentID: String; let path: String; let lastSize: UInt64; let needsMeta: Bool }
        struct Result: Sendable {
            let job: Job
            let size: UInt64
            let activity: SubagentTranscript.Activity?
            let meta: SubagentTranscript.Meta?
        }
        var jobs: [Job] = []
        for pane in panes {
            for track in pane.subagents where track.info.state == .running || !track.metaLoaded {
                guard let path = track.transcriptPath else { continue }
                jobs.append(Job(paneID: pane.id, agentID: track.info.id, path: path, lastSize: track.transcriptSize,
                                needsMeta: !track.metaLoaded))
            }
        }
        guard !jobs.isEmpty else { return done() }
        DispatchQueue.global(qos: .utility).async {
            let results = jobs.map { job -> Result in
                let size = ((try? FileManager.default.attributesOfItem(atPath: job.path))?[.size] as? NSNumber)?.uint64Value ?? 0
                let activity = size != job.lastSize && size > 0 ? SubagentTranscript.activity(path: job.path) : nil
                let meta = job.needsMeta ? SubagentTranscript.meta(transcriptPath: job.path) : nil
                return Result(job: job, size: size, activity: activity, meta: meta)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for result in results {
                        guard let pane = self.pane(id: result.job.paneID),
                              let index = pane.subagents.firstIndex(where: { $0.info.id == result.job.agentID }) else { continue }
                        var track = pane.subagents[index]
                        if result.size != track.transcriptSize, result.size > 0 {
                            track.transcriptSize = result.size
                            track.lastSeenAt = max(track.lastSeenAt, now)
                        }
                        if let activity = result.activity {
                            track.info.action = activity.action
                            if let tokens = activity.tokens { track.info.tokens = tokens }
                        }
                        if let meta = result.meta {
                            track.metaLoaded = true
                            if track.info.agentType == nil { track.info.agentType = meta.agentType }
                            track.info.description = meta.description ?? track.info.description
                        }
                        pane.subagents[index] = track
                    }
                    done()
                }
            }
        }
    }
}

extension Workspace {
    /// Subagents of the workspace's panes, in reading order then by start (running and recently done).
    var subagents: [SubagentInfo] {
        let now = Date()
        return orderedPanes.flatMap { pane in pane.subagents.map { AppController.liveInfo($0.info, now: now) } }
    }

    var runningSubagentCount: Int {
        panes.values.reduce(0) { $0 + $1.subagents.filter { $0.info.state == .running }.count }
    }
}
