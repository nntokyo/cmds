import Foundation

/// Splits a byte stream into `\n`-terminated lines (used by both ends of the socket API).
/// Lines longer than `maxLineLength` are rejected so a peer cannot exhaust memory.
public struct JSONLineBuffer: Sendable {
    public static let defaultMaxLineLength = 8 * 1024 * 1024

    public struct LineTooLong: Error, CustomStringConvertible, Sendable {
        public let limit: Int
        public var description: String { "line exceeds \(limit) bytes" }
    }

    public let maxLineLength: Int
    private var buffer = Data()
    /// Bytes of `buffer` already scanned without finding a newline.
    private var scanned = 0

    public init(maxLineLength: Int = JSONLineBuffer.defaultMaxLineLength) {
        self.maxLineLength = maxLineLength
    }

    /// Bytes buffered for the current, incomplete line.
    public var pendingCount: Int { buffer.count }

    /// Appends `data` and returns every complete line (without the newline; a trailing `\r` is stripped).
    /// Empty lines are skipped.
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        var start = buffer.startIndex
        var index = buffer.startIndex + scanned
        while index < buffer.endIndex {
            if buffer[index] == 0x0A {
                var end = index
                if end > start, buffer[end - 1] == 0x0D { end -= 1 }
                if end > start {
                    guard end - start <= maxLineLength else { throw LineTooLong(limit: maxLineLength) }
                    lines.append(Data(buffer[start..<end]))
                }
                start = index + 1
            }
            index += 1
        }
        if start > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start) }
        scanned = buffer.count
        guard buffer.count <= maxLineLength else { throw LineTooLong(limit: maxLineLength) }
        return lines
    }

    /// Encodes a value as one compact JSON line (`\n` terminated).
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}
