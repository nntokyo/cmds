import Foundation
import CmdsCore

/// `schedule.*` on the local socket (docs/reference/api.md "Schedules"). Never on an SSH pane's socket: the methods are
/// not in `RemoteAPIPolicy.allowedMethods` (RemoteAccessTests).
@MainActor
enum ScheduleAPI {
    static func perform(_ method: String, _ params: Params, runner: ScheduleRunner) throws -> JSONValue? {
        switch method {
        case "schedule.list":
            return try .from(runner.list())
        case "schedule.add":
            let draft = try decode(ScheduleDraft.self, from: try params.json("schedule"), what: "schedule")
            let schedule = try runner.add(draft, origin: .api(pane: try params.string("pane")))
            return try .from(runner.entry(schedule))
        case "schedule.update":
            let id = try params.required("id")
            let name = try params.string("name")
            let enabled = try params.bool("enabled")
            let trigger = try optional("trigger", params, as: ScheduleTrigger.self)
            let action = try optional("action", params, as: ScheduleAction.self)
            let late = try optional("late", params, as: ScheduleLatePolicy.self)
            let notify = try params.value("notify", as: ScheduleNotify.self, invalid: "notify must be failures, always or never")
            let warn = try params.bool("warn")
            let schedule = try runner.update(id: id) { draft in
                if let name { draft.name = name }
                if let enabled { draft.enabled = enabled }
                if let trigger { draft.trigger = trigger }
                if let action { draft.action = action }
                if let late { draft.late = late }
                if let notify { draft.notify = notify }
                if let warn { draft.warn = warn }
            }
            return try .from(runner.entry(schedule))
        case "schedule.remove":
            try runner.remove(id: try params.required("id"))
            return nil
        case "schedule.run":
            return ["run": try .from(try runner.runNow(id: try params.required("id")))]
        case "schedule.skip":
            return ["run": try .from(try runner.skip(id: try params.required("id")))]
        case "schedule.cancel":
            try runner.cancel(runID: try params.required("run"))
            return nil
        case "schedule.history":
            let limit = min(try params.int("limit") ?? ScheduleLimits.defaultHistoryLimit, ScheduleLimits.maxRuns)
            let id = try params.string("id")
            if let id, runner.schedule(id: id) == nil, !runner.history.contains(where: { $0.scheduleID == id }) {
                throw RPCError.notFound("schedule not found: \(id)")
            }
            return try .from(ScheduleHistoryList(runs: runner.runs(scheduleID: id, limit: limit)))
        default:
            throw RPCError.methodNotFound(method)
        }
    }

    private static func optional<T: Decodable>(_ key: String, _ params: Params, as type: T.Type) throws -> T? {
        switch params.value?[key] {
        case nil, .null?: return nil
        case let value?: return try decode(type, from: value, what: key)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue, what: String) throws -> T {
        do {
            return try value.decode(type)
        } catch let DecodingError.dataCorrupted(context) {
            throw RPCError.invalidParams("\(what) is not valid: \(context.debugDescription)")
        } catch let DecodingError.keyNotFound(key, _) {
            throw RPCError.invalidParams("\(what) is not valid: missing \(key.stringValue)")
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context) {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw RPCError.invalidParams("\(what) is not valid: wrong type at \(path.isEmpty ? what : path)")
        } catch {
            throw RPCError.invalidParams("\(what) is not valid")
        }
    }
}
