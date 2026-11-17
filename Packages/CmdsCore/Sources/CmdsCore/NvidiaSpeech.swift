import Foundation

/// NVIDIA's hosted speech synthesis (build.nvidia.com, "Nemotron Speech" / Riva TTS, Magpie TTS Multilingual) for the
/// assistant's voice, when the user chose an NVIDIA voice and gave an API key. The service is gRPC on
/// `grpc.nvcf.nvidia.com` (NVIDIA Cloud Functions: the model is picked by the `function-id` header); a unary call is a
/// plain HTTP/2 POST, so this file only encodes and decodes the few protobuf messages and gRPC frames it needs
/// (`riva_tts.proto`, MIT): no gRPC library. Only the answer's text is sent, never audio from the microphone.
public enum NvidiaSpeech {
    public static let host = "grpc.nvcf.nvidia.com"
    /// `RivaSpeechSynthesis.Synthesize` (unary).
    public static let synthesizePath = "/nvidia.riva.tts.RivaSpeechSynthesis/Synthesize"
    /// `RivaSpeechSynthesis.GetRivaSynthesisConfig` (unary): the voices.
    public static let configPath = "/nvidia.riva.tts.RivaSpeechSynthesis/GetRivaSynthesisConfig"
    /// The list of NVIDIA Cloud Functions the key may call (`functionID(in:name:)`).
    public static let functionsURL = URL(string: "https://api.nvcf.nvidia.com/v2/nvcf/functions?visibility=public,authorized")!
    /// The function name of Magpie TTS Multilingual in that list.
    public static let ttsFunctionName = "ai-magpie-tts-multilingual"
    /// Signed 16-bit little-endian mono PCM at this rate (`AudioEncoding.LINEAR_PCM`).
    public static let sampleRate = 22_050
    /// Where an NVIDIA voice is kept in the assistant's voice setting: `nvidia:<voice name>`.
    public static let voicePrefix = "nvidia:"
    /// The longest text sent at once (the reply is limited to 4 MB of audio, about 90 s at `sampleRate`).
    public static let maxCharacters = 400

    // MARK: Voices

    /// `nvidia:Magpie-Multilingual.JA-JP.Ray` → `Magpie-Multilingual.JA-JP.Ray`; nil for a voice of this Mac.
    public static func voiceName(fromSetting setting: String?) -> String? {
        guard let setting, setting.hasPrefix(voicePrefix) else { return nil }
        let name = String(setting.dropFirst(voicePrefix.count))
        return isValidVoiceName(name) ? name : nil
    }

    public static func setting(forVoice name: String) -> String { voicePrefix + name }

    /// Voice names are `Model.LOCALE.Speaker[.Emotion]`: letters, digits, `.`, `-`, `_`.
    public static func isValidVoiceName(_ name: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return (1...128).contains(name.count) && name.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// The language of a voice name as a BCP 47 code (`…JA-JP…` → `ja-JP`); nil when it has none.
    public static func language(ofVoice name: String) -> String? {
        for part in name.split(separator: ".") {
            let pieces = part.split(separator: "-")
            guard pieces.count == 2, pieces[0].count == 2, pieces[1].count == 2,
                  part.allSatisfy({ $0.isLetter || $0 == "-" }) else { continue }
            return pieces[0].lowercased() + "-" + pieces[1].uppercased()
        }
        return nil
    }

    /// The speaker part of a voice name, for showing it (`Magpie-Multilingual.JA-JP.Ray` → `Ray`,
    /// `….EN-US.Aria.Calm` → `Aria (Calm)`).
    public static func displayName(ofVoice name: String) -> String {
        let parts = name.split(separator: ".").map(String.init)
        guard let locale = parts.firstIndex(where: { language(ofVoice: $0) != nil }), locale + 1 < parts.count else { return name }
        let speaker = parts[locale + 1]
        let rest = parts.dropFirst(locale + 2)
        return rest.isEmpty ? speaker : "\(speaker) (\(rest.joined(separator: " ")))"
    }

    /// The voices in a `GetRivaSynthesisConfig` reply: each model's `voice_name` and `subvoices` parameters
    /// (`subvoices` lists `Speaker:index` or `Speaker` entries, comma separated, added after the model's voice name
    /// prefix). Sorted, without duplicates.
    public static func voices(fromConfig reply: Data) -> [String] {
        var voices = Set<String>()
        for config in Protobuf.fields(reply).filter({ $0.number == 1 }).compactMap(\.bytes) {
            var parameters: [String: String] = [:]
            for entry in Protobuf.fields(config).filter({ $0.number == 2 }).compactMap(\.bytes) {
                let pair = Protobuf.fields(entry)
                if let key = pair.first(where: { $0.number == 1 })?.string, let value = pair.first(where: { $0.number == 2 })?.string {
                    parameters[key] = value
                }
            }
            guard let base = parameters["voice_name"], !base.isEmpty else { continue }
            let subvoices = (parameters["subvoices"] ?? "").split(separator: ",")
                .map { $0.split(separator: ":").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "" }
                .filter { !$0.isEmpty }
            if subvoices.isEmpty {
                voices.insert(base)
            } else {
                for subvoice in subvoices { voices.insert(base + "." + subvoice) }
            }
        }
        return voices.filter(isValidVoiceName).sorted()
    }

    // MARK: Requests and replies

    /// `SynthesizeSpeechRequest`: text, language, LINEAR_PCM at `sampleRate`, voice.
    public static func synthesizeRequest(text: String, language: String, voice: String) -> Data {
        var message = Data()
        Protobuf.appendString(text, field: 1, to: &message)
        Protobuf.appendString(language, field: 2, to: &message)
        Protobuf.appendVarint(1, field: 3, to: &message) // LINEAR_PCM
        Protobuf.appendVarint(UInt64(sampleRate), field: 4, to: &message)
        Protobuf.appendString(voice, field: 5, to: &message)
        return message
    }

    /// `RivaSynthesisConfigRequest` without a model name: every model's configuration.
    public static func configRequest() -> Data { Data() }

    /// The PCM samples of a `SynthesizeSpeechResponse` (field 1).
    public static func audio(fromResponse response: Data) -> Data? {
        Protobuf.fields(response).first { $0.number == 1 }?.bytes
    }

    /// A gRPC message frame: uncompressed flag, big-endian length, the message.
    public static func frame(_ message: Data) -> Data {
        var frame = Data([0])
        let length = UInt32(message.count)
        frame.append(contentsOf: [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        frame.append(message)
        return frame
    }

    /// The messages of a gRPC reply body; nil when it is cut short or compressed (never asked for).
    public static func messages(inBody body: Data) -> [Data]? {
        var messages: [Data] = []
        var index = body.startIndex
        while index < body.endIndex {
            guard body.endIndex - index >= 5, body[index] == 0 else { return nil }
            let length = body[(index + 1)...(index + 4)].reduce(0) { $0 << 8 | Int($1) }
            let start = index + 5
            guard body.endIndex - start >= length else { return nil }
            messages.append(Data(body[start..<(start + length)]))
            index = start + length
        }
        return messages
    }

    /// The HTTP/2 request headers of a call (besides `:path`): the key as a bearer token, the function.
    public static func headers(apiKey: String, functionID: String) -> [String: String] {
        ["content-type": "application/grpc", "te": "trailers", "authorization": "Bearer \(apiKey)",
         "function-id": functionID, "grpc-accept-encoding": "identity"]
    }

    /// A gRPC error carried in the reply's headers (a "trailers-only" reply: a refused key, an unknown function):
    /// `grpc-status` other than 0, with `grpc-message` (percent-encoded). nil when the headers have none or 0.
    public static func error(inHeaders headers: [String: String]) -> String? {
        let lowered = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        guard let status = lowered["grpc-status"], status != "0" else { return nil }
        let message = lowered["grpc-message"].flatMap { $0.removingPercentEncoding } ?? ""
        return message.isEmpty ? "gRPC status \(status)" : "gRPC status \(status): \(message)"
    }

    /// The id of the active function `name` in the functions list (`functionsURL`).
    public static func functionID(in json: Data, name: String = ttsFunctionName) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let functions = object["functions"] as? [[String: Any]] else { return nil }
        let matching = functions.filter { $0["name"] as? String == name }
        let active = matching.first { ($0["status"] as? String)?.uppercased() == "ACTIVE" } ?? matching.first
        return active?["id"] as? String
    }

    // MARK: Text

    /// The text cut into pieces of at most `limit` characters, at sentence ends (。．！？!? and line breaks), else at
    /// commas or spaces, else anywhere. Empty pieces are dropped.
    public static func pieces(_ text: String, limit: Int = maxCharacters) -> [String] {
        var pieces: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            if rest.count <= limit {
                pieces.append(String(rest))
                break
            }
            let window = rest.prefix(limit)
            let cut = window.lastIndex(where: { "。．！？!?\n".contains($0) })
                ?? window.lastIndex(where: { "、，,;； ".contains($0) })
            let end = cut.map { rest.index(after: $0) } ?? window.endIndex
            pieces.append(String(rest[..<end]))
            rest = rest[end...]
        }
        return pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

/// The little of protobuf's wire format `NvidiaSpeech` needs: varints and length-delimited fields.
enum Protobuf {
    struct Field {
        var number: Int
        var varint: UInt64?
        var bytes: Data?
        var string: String? { bytes.flatMap { String(data: $0, encoding: .utf8) } }
    }

    static func appendVarint(_ value: UInt64, to data: inout Data) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }

    static func appendVarint(_ value: UInt64, field: Int, to data: inout Data) {
        appendVarint(UInt64(field << 3), to: &data)
        appendVarint(value, to: &data)
    }

    static func appendBytes(_ bytes: Data, field: Int, to data: inout Data) {
        appendVarint(UInt64(field << 3 | 2), to: &data)
        appendVarint(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    static func appendString(_ string: String, field: Int, to data: inout Data) {
        appendBytes(Data(string.utf8), field: field, to: &data)
    }

    /// The fields of a message, in order; stops at the first malformed one. Fixed 32/64-bit fields are skipped.
    static func fields(_ data: Data) -> [Field] {
        var fields: [Field] = []
        var index = data.startIndex
        func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < data.endIndex, shift < 64 {
                let byte = data[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while index < data.endIndex {
            guard let key = varint() else { break }
            let number = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let value = varint() else { return fields }
                fields.append(Field(number: number, varint: value))
            case 2:
                guard let length = varint(), UInt64(data.endIndex - index) >= length else { return fields }
                let end = index + Int(length)
                fields.append(Field(number: number, bytes: Data(data[index..<end])))
                index = end
            case 1:
                guard data.endIndex - index >= 8 else { return fields }
                index += 8
            case 5:
                guard data.endIndex - index >= 4 else { return fields }
                index += 4
            default:
                return fields
            }
        }
        return fields
    }
}
