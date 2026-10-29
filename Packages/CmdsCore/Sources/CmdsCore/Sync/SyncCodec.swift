import Foundation

/// Encodes/decodes sync messages to the bytes of one WebSocket text frame (UTF-8 JSON).
/// Stateless and cheap to create; not thread-safe across concurrent calls on the same instance.
public struct SyncCodec {
    /// Upper bound for an incoming frame. Larger frames are rejected before parsing.
    public static let maxFrameBytes = 4 * 1024 * 1024

    public enum DecodeError: Error, Equatable {
        case frameTooLarge(Int)
    }

    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(prettyPrinted: Bool = false) {
        encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
    }

    public func encode(_ message: ClientMessage) throws -> Data { try encoder.encode(message) }
    public func encode(_ message: ServerMessage) throws -> Data { try encoder.encode(message) }

    public func decodeClientMessage(_ data: Data) throws -> ClientMessage {
        try checkSize(data)
        return try decoder.decode(ClientMessage.self, from: data)
    }

    public func decodeServerMessage(_ data: Data) throws -> ServerMessage {
        try checkSize(data)
        return try decoder.decode(ServerMessage.self, from: data)
    }

    /// `type` field of a frame without decoding the payload (logging / unknown-type replies).
    public func peekType(_ data: Data) -> String? {
        struct Envelope: Decodable { var type: String }
        return try? decoder.decode(Envelope.self, from: data).type
    }

    private func checkSize(_ data: Data) throws {
        if data.count > Self.maxFrameBytes { throw DecodeError.frameTooLarge(data.count) }
    }
}
