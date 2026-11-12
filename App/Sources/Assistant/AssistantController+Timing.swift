import CmdsCore
import Foundation
import os

private let timingLog = Logger(subsystem: "tokyo.n-n.cmds", category: "assistant")

/// How long each request took, stage by stage (#248: `AssistantTimeline`): kept for `debug.assistant` (the current
/// and the last few requests) and logged once the answer goes to the voice, with stage names and milliseconds only.
@available(macOS 26.0, *)
extension AssistantController {
    /// How many requests' timelines `debug.assistant` keeps.
    static let keptTimelines = 10

    /// A new request was heard at `start` (`speechEnd`: the last loud audio before its transcript, from the
    /// microphone).
    func beginTimeline(at start: Date, speechEnd: Date?) {
        var timeline = AssistantTimeline(request: machine.request, start: start)
        timeline.mark(.heard, at: start)
        if let speechEnd { timeline.mark(.speechEnd, at: speechEnd) }
        self.timeline = timeline
        keep(timeline)
    }

    /// Notes a stage of `request` (default: the current one); nothing when the user has moved on.
    func mark(_ stage: AssistantTimeline.Stage, request: Int? = nil, at date: Date = Date()) {
        guard var timeline, timeline.request == (request ?? machine.request) else { return }
        let first = timeline.marks[stage] == nil
        timeline.mark(stage, at: date)
        self.timeline = timeline
        keep(timeline)
        if stage == .speechStart, first {
            timingLog.notice("assistant timing r\(timeline.request, privacy: .public) \(timeline.summary, privacy: .public)")
        }
    }

    /// The way the current request went ("web", "status"…); the last one said counts ("model" then "web").
    func route(_ route: String) {
        guard var timeline, timeline.request == machine.request else { return }
        timeline.route = route
        self.timeline = timeline
        keep(timeline)
    }

    /// Stages reported from `AssistantBrain` on any thread, noted for `request` on the main actor.
    func progress(for request: Int) -> AssistantBrain.Progress {
        { [weak self] stage, date in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.mark(stage, request: request, at: date) } }
        }
    }

    private func keep(_ timeline: AssistantTimeline) {
        if let index = timelines.lastIndex(where: { $0.request == timeline.request }) {
            timelines[index] = timeline
        } else {
            timelines.append(timeline)
            if timelines.count > Self.keptTimelines { timelines.removeFirst(timelines.count - Self.keptTimelines) }
        }
    }
}
