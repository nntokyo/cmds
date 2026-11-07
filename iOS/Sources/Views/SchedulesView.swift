import CmdsCore
import SwiftUI

/// The Mac's schedules and their recent runs, read only (⋯ › Schedules, #45 phase 3). Shown only for Macs that send
/// them (`SyncFeature.schedules`); schedules are made and changed on the Mac (Window › Schedules, `cmds schedule`).
struct SchedulesView: View {
    @Environment(CompanionClient.self) private var client
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Schedules")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let list = client.schedules {
            if list.schedules.isEmpty && list.runs.isEmpty {
                ContentUnavailableView {
                    Label("No Schedules", systemImage: "calendar.badge.clock")
                } description: {
                    Text("Make schedules on the Mac in Window › Schedules… or with cmds schedule add.")
                }
            } else {
                // A minute timer keeps "today 15:00" / "Thu 09:00" right while the list stays open.
                TimelineView(.everyMinute) { context in
                    ScheduleList(list: list, now: context.date)
                }
            }
        } else {
            ContentUnavailableView {
                Label(client.status.isLive ? String(localized: "Loading Schedules…") : client.status.label,
                      systemImage: "calendar.badge.clock")
            }
        }
    }
}

private struct ScheduleList: View {
    let list: ServerMessage.Schedules
    let now: Date

    var body: some View {
        List {
            Section {
                ForEach(list.schedules, id: \.id) { schedule in
                    ScheduleRow(schedule: schedule, now: now)
                }
            } footer: {
                if list.readOnly == true {
                    Text("These schedules were made by a newer cmds and do not run on this Mac.")
                } else {
                    Text("Read only. Change schedules on the Mac in Window › Schedules….")
                }
            }
            if !list.runs.isEmpty {
                Section("Recent Runs") {
                    ForEach(list.runs, id: \.id) { run in
                        ScheduleRunRow(run: run, now: now)
                    }
                }
            }
        }
        .accessibilityIdentifier("schedulesList")
    }
}

private struct ScheduleRow: View {
    let schedule: SyncScheduleSummary
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(schedule.name).font(.headline).lineLimit(1)
                Spacer()
                if !schedule.enabled {
                    Text("Off")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
            if let trigger = schedule.trigger {
                Label(ScheduleStrings.trigger(trigger, now: now), systemImage: "clock")
                    .font(.subheadline)
            }
            if let action = ScheduleActionText.text(schedule.action) {
                Label(action, systemImage: "terminal")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let next = schedule.nextFireAt {
                Text("Next: \(ScheduleStrings.time(next, now: now))")
                    .font(.subheadline.monospacedDigit())
            } else if schedule.enabled {
                Text("No next run").font(.subheadline).foregroundStyle(.secondary)
            }
            if let active = schedule.activeRun {
                RunOutcomeLine(run: active, now: now, prefix: String(localized: "Now:"))
            } else if let last = schedule.lastRun {
                RunOutcomeLine(run: last, now: now, prefix: String(localized: "Last:"))
            }
        }
        .padding(.vertical, 2)
        .opacity(schedule.enabled ? 1 : 0.6)
        .accessibilityElement(children: .combine)
    }
}

private struct ScheduleRunRow: View {
    let run: ScheduleRun
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                RunStateLabel(state: run.state)
                Text(run.scheduleName).lineLimit(1)
                Spacer()
                Text(ScheduleStrings.time(run.lastActivityAt, now: now))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let detail = RunText.detail(run) {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// `Last: ✓ Succeeded · Thu 09:00` and the reason below it.
private struct RunOutcomeLine: View {
    let run: ScheduleRun
    let now: Date
    let prefix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(verbatim: prefix).foregroundStyle(.secondary)
                RunStateLabel(state: run.state)
                Text(verbatim: "· \(ScheduleStrings.time(run.lastActivityAt, now: now))").foregroundStyle(.secondary)
            }
            if let reason = run.reason, run.state != .succeeded || reason == .unconfirmed {
                Text(ScheduleStrings.reason(reason)).foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }
}

private struct RunStateLabel: View {
    let state: ScheduleRunState

    var body: some View {
        Label {
            Text(ScheduleStrings.state(state))
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .labelStyle(.titleAndIcon)
    }

    private var symbol: String {
        switch state {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .skipped: return "forward.end.circle.fill"
        case .missed: return "moon.zzz.fill"
        case .cancelled: return "minus.circle.fill"
        case .waitingForAccount, .waitingForPane, .typing, .waitingForAgent, .confirming: return "hourglass"
        }
    }

    private var color: Color {
        switch state {
        case .succeeded: return .green
        case .failed: return .red
        case .skipped, .missed: return .orange
        case .cancelled: return .secondary
        case .waitingForAccount, .waitingForPane, .typing, .waitingForAgent, .confirming: return .blue
        }
    }
}

private enum RunText {
    /// `Catch-up · The pane was running another program.`; nil when there is nothing to add.
    static func detail(_ run: ScheduleRun) -> String? {
        var parts: [String] = []
        if run.cause != .scheduled { parts.append(ScheduleStrings.cause(run.cause)) }
        if let reason = run.reason { parts.append(ScheduleStrings.reason(reason)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// What a schedule does, from the summary the Mac sends (no prompts, commands or folders reach the phone).
enum ScheduleActionText {
    static func text(_ action: SyncScheduleAction) -> String? {
        switch action.type {
        case "startWorkspace":
            return String(localized: "Opens a new workspace")
        case "continueSession":
            return action.agent == .codex ? String(localized: "Continues a Codex session")
                : String(localized: "Continues a Claude Code session")
        case "sendText":
            return action.to == .agent ? String(localized: "Sends a prompt to the agent in a pane")
                : String(localized: "Types a command in a pane")
        default:
            return nil
        }
    }
}
