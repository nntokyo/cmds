import CmdsCore
import Foundation

/// `transfer.*` on the app's socket (docs/reference/api.md "Transfers"); refused on SSH panes' sockets.
extension TransferCenter {
    func perform(_ method: String, _ params: Params) throws -> JSONValue? {
        func id() throws -> Int {
            guard let id = try params.int("id"), id > 0 else { throw RPCError.invalidParams("id must be a transfer number") }
            return id
        }
        switch method {
        case "transfer.list":
            return try .from(queue.snapshots.map(TransferInfo.init))
        case "transfer.pause":
            try pause(id: try id())
        case "transfer.resume":
            try resume(id: try id())
        case "transfer.cancel":
            try cancel(id: try id())
        case "transfer.retry":
            try retry(id: try id())
        case "transfer.clear":
            clearFinished()
        default:
            throw RPCError.methodNotFound(method)
        }
        return nil
    }

    #if DEBUG
    /// Tests: every job with its whole log.
    func debugState() -> JSONValue {
        .array(queue.snapshots.map { job in
            .object([
                "id": .number(Double(job.id)),
                "state": .string(job.state.rawValue),
                "error": job.error.map { .string($0.description) } ?? .null,
                "log": .array(job.log.map { .string("\($0.path): \($0.outcome)") }),
            ])
        })
    }
    #endif
}
