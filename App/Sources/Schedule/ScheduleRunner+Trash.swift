import Foundation
import CmdsCore

/// Recently Deleted (`schedules-deleted.json`, #449): every schedule removed, and every element of `schedules.json`
/// dropped while it was read, is kept as it was for `ScheduleTrash.retention`, so a schedule's folder and prompt are
/// never lost with it. `schedule.deleted` lists them; `schedule.restore` puts one back.
extension ScheduleRunner {
    func loadTrash() {
        switch StoredFile.load(ScheduleTrash.self, from: trashURL) {
        case .missing:
            break
        case .loaded(let file):
            trash = file
            trash.trim(now: now())
            // A newer cmds' file is kept as it is.
            if file.version > ScheduleTrash.currentVersion { trashLocked = true }
        case .unreadable(let error, let movedTo):
            if case .failure = movedTo { trashLocked = true }
            scheduleLog.error("\(ScheduleTrash.fileName, privacy: .public) could not be read: \(String(describing: error), privacy: .public)")
        }
    }

    func saveTrash() {
        guard !trashLocked else { return }
        do {
            try ScheduleStore.save(trash, to: trashURL)
        } catch {
            scheduleLog.error("could not save deleted schedules: \(String(describing: error), privacy: .public)")
        }
    }

    func keepRemoved(_ schedule: Schedule, by origin: ScheduleOrigin) {
        guard let json = try? JSONValue.from(schedule) else { return }
        trash.add(DeletedSchedule(schedule: json, deletedAt: now(), reason: .removed, removedBy: origin), now: now())
        saveTrash()
    }

    func keepDropped(_ dropped: [(json: JSONValue, problem: String)]) {
        for element in dropped {
            trash.add(DeletedSchedule(schedule: element.json, deletedAt: now(), reason: .dropped, problem: element.problem),
                      now: now())
        }
        scheduleLog.error("kept \(dropped.count) dropped schedules in \(ScheduleTrash.fileName, privacy: .public)")
        saveTrash()
    }

    func deletedList() -> DeletedScheduleList {
        trash.trim(now: now())
        return DeletedScheduleList(deleted: trash.deleted)
    }

    /// Puts the newest deleted schedule `id` back, under a new id if a schedule has taken it. Checked as an edit is: a
    /// time that has passed does not stop it, and a one-time schedule whose time passed comes back with no next run.
    @discardableResult
    func restore(id: String) throws -> Schedule {
        try requireWritable()
        guard let index = trash.index(of: id) else { throw RPCError.notFound("no deleted schedule \(id)") }
        let entry = trash.deleted[index]
        guard var schedule = entry.decoded else {
            throw RPCError.invalidParams("deleted schedule \(id) cannot be restored as it is (\(entry.problem ?? "it cannot be read")); "
                                         + "`cmds schedule deleted --json` shows what it was")
        }
        let problems = problems(schedule.draft, excluding: nil, full: false)
        guard problems.isEmpty else {
            throw RPCError.invalidParams("deleted schedule \(id) cannot be restored: " + problems.map(\.english).joined(separator: "; "))
        }
        let taken = Set(schedules.map(\.id))
        if taken.contains(schedule.id) {
            schedule.id = ScheduleIDs.make(prefix: ScheduleIDs.schedulePrefix, taken: taken)
        }
        schedule.nextFireAt = schedule.enabled ? nextFire(schedule, after: now()) : nil
        appendRestored(schedule)
        trash.deleted.remove(at: index)
        scheduleLog.info("restored schedule \(id, privacy: .public) as \(schedule.id, privacy: .public)")
        saveTrash()
        save()
        emit(.schedules(id: schedule.id))
        checkDue()
        return self.schedule(id: schedule.id) ?? schedule
    }
}

extension ScheduleOrigin {
    /// For the log: `window`, `api` or `api p12`.
    var logDescription: String {
        switch self {
        case .app: return "window"
        case .api(let pane): return pane.map { "api \($0)" } ?? "api"
        }
    }
}
