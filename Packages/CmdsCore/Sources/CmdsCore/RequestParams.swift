import Foundation

/// Typed reads of a request's params for the request types of this package (the app's own is `Params`). `null` counts
/// as absent; a value of the wrong type is `invalidParams("<key> must be …")`.
struct RequestParams {
    let value: JSONValue?

    init(_ value: JSONValue?) { self.value = value }

    /// The value at `key`; nil when absent or `null`.
    subscript(key: String) -> JSONValue? {
        if case .null? = value?[key] { return nil }
        return value?[key]
    }

    func string(_ key: String) throws -> String? {
        switch self[key] {
        case nil: return nil
        case .string(let string)?: return string
        default: throw RPCError.invalidParams("\(key) must be a string")
        }
    }

    func bool(_ key: String) throws -> Bool? {
        switch self[key] {
        case nil: return nil
        case .bool(let flag)?: return flag
        default: throw RPCError.invalidParams("\(key) must be a boolean")
        }
    }

    /// A whole number below a million (a width or height to check against `ViewportSize.range`).
    func cssPixels(_ key: String) throws -> Int? {
        switch self[key] {
        case nil: return nil
        case .number(let number)? where number.rounded() == number && abs(number) < 1e6: return Int(number)
        default: throw RPCError.invalidParams("\(key) must be a whole number of CSS pixels")
        }
    }
}
