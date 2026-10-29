import Foundation

/// Minimal DER (ITU-T X.690) encoder: only the types the sync certificate needs (`SyncCertificate`).
/// Every function returns a complete TLV (tag, definite length, value).
public enum DER {
    public static func tlv(tag: UInt8, _ value: [UInt8]) -> [UInt8] {
        [tag] + length(value.count) + value
    }

    /// Definite length: short form below 128, else long form (0x80 | number of bytes, big endian).
    static func length(_ count: Int) -> [UInt8] {
        precondition(count >= 0)
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var n = count
        while n > 0 {
            bytes.insert(UInt8(n & 0xFF), at: 0)
            n >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    public static func sequence(_ elements: [[UInt8]]) -> [UInt8] {
        tlv(tag: 0x30, elements.flatMap { $0 })
    }

    /// SET OF; DER orders the elements by their encodings.
    public static func set(_ elements: [[UInt8]]) -> [UInt8] {
        tlv(tag: 0x31, elements.sorted { $0.lexicographicallyPrecedes($1) }.flatMap { $0 })
    }

    public static func boolean(_ value: Bool) -> [UInt8] {
        [0x01, 0x01, value ? 0xFF : 0x00]
    }

    /// Non-negative INTEGER from big-endian magnitude bytes: leading zeros are dropped and a 0x00 is
    /// prepended when the top bit is set, so the value stays positive.
    public static func integer(unsigned magnitude: [UInt8]) -> [UInt8] {
        var bytes = Array(magnitude.drop { $0 == 0 })
        if bytes.isEmpty { bytes = [0] }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(tag: 0x02, bytes)
    }

    public static func integer(_ value: UInt64) -> [UInt8] {
        integer(unsigned: withUnsafeBytes(of: value.bigEndian) { Array($0) })
    }

    /// OBJECT IDENTIFIER from dotted notation, e.g. "1.2.840.10045.2.1".
    public static func objectIdentifier(_ dotted: String) -> [UInt8] {
        let arcs = dotted.split(separator: ".").map { UInt64($0) }
        precondition(arcs.count >= 2 && arcs.allSatisfy { $0 != nil }, "bad OID \(dotted)")
        let values = arcs.map { $0! }
        precondition(values[0] <= 2 && (values[0] == 2 || values[1] < 40), "bad OID \(dotted)")
        var body = base128(values[0] * 40 + values[1])
        for arc in values.dropFirst(2) { body += base128(arc) }
        return tlv(tag: 0x06, body)
    }

    private static func base128(_ value: UInt64) -> [UInt8] {
        var rest = value >> 7
        var out: [UInt8] = [UInt8(value & 0x7F)]
        while rest > 0 {
            out.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
            rest >>= 7
        }
        return out
    }

    public static func utf8String(_ string: String) -> [UInt8] {
        tlv(tag: 0x0C, Array(string.utf8))
    }

    public static func octetString(_ bytes: [UInt8]) -> [UInt8] {
        tlv(tag: 0x04, bytes)
    }

    public static func bitString(_ bytes: [UInt8], unusedBits: UInt8 = 0) -> [UInt8] {
        precondition(unusedBits < 8)
        return tlv(tag: 0x03, [unusedBits] + bytes)
    }

    /// Certificate validity time (RFC 5280 §4.1.2.5): UTCTime for 1950–2049, GeneralizedTime otherwise.
    /// Whole seconds, UTC ("Z").
    public static func time(_ date: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = c.year ?? 1970
        let rest = String(format: "%02d%02d%02d%02d%02dZ", c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        if (1950...2049).contains(year) {
            return tlv(tag: 0x17, Array((String(format: "%02d", year % 100) + rest).utf8))
        }
        return tlv(tag: 0x18, Array((String(format: "%04d", year) + rest).utf8))
    }

    /// Context-specific constructed tag `[number]` around `content` (EXPLICIT tagging).
    public static func explicit(_ number: UInt8, _ content: [UInt8]) -> [UInt8] {
        precondition(number < 31)
        return tlv(tag: 0xA0 | number, content)
    }
}
