@testable import CmdsCore
import XCTest

final class NvidiaSpeechTests: XCTestCase {
    func testVoiceSetting() {
        XCTAssertEqual(NvidiaSpeech.voiceName(fromSetting: "nvidia:Magpie-Multilingual.JA-JP.Ray"), "Magpie-Multilingual.JA-JP.Ray")
        XCTAssertNil(NvidiaSpeech.voiceName(fromSetting: "com.apple.voice.compact.ja-JP.Kyoko"))
        XCTAssertNil(NvidiaSpeech.voiceName(fromSetting: nil))
        XCTAssertNil(NvidiaSpeech.voiceName(fromSetting: "nvidia:bad name"))
        XCTAssertEqual(NvidiaSpeech.setting(forVoice: "A.JA-JP.B"), "nvidia:A.JA-JP.B")
        XCTAssertEqual(NvidiaSpeech.language(ofVoice: "Magpie-Multilingual.JA-JP.Ray"), "ja-JP")
        XCTAssertEqual(NvidiaSpeech.language(ofVoice: "Magpie-Multilingual.EN-US.Aria.Calm"), "en-US")
        XCTAssertNil(NvidiaSpeech.language(ofVoice: "Magpie"))
        XCTAssertEqual(NvidiaSpeech.displayName(ofVoice: "Magpie-Multilingual.JA-JP.Ray"), "Ray")
        XCTAssertEqual(NvidiaSpeech.displayName(ofVoice: "Magpie-Multilingual.EN-US.Aria.Calm"), "Aria (Calm)")
    }

    func testRequestEncoding() {
        let request = NvidiaSpeech.synthesizeRequest(text: "こんにちは", language: "ja-JP", voice: "V")
        let fields = Protobuf.fields(request)
        XCTAssertEqual(fields.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(fields[0].string, "こんにちは")
        XCTAssertEqual(fields[1].string, "ja-JP")
        XCTAssertEqual(fields[2].varint, 1)
        XCTAssertEqual(fields[3].varint, 22_050)
        XCTAssertEqual(fields[4].string, "V")
        // 22050 as a varint: 0xA2 0xAC 0x01 after the key 0x20.
        XCTAssertNotNil(request.range(of: Data([0x20, 0xA2, 0xAC, 0x01])))
    }

    func testFramesAndAudio() {
        var response = Data()
        Protobuf.appendBytes(Data([1, 2, 3, 4]), field: 1, to: &response)
        var meta = Data()
        Protobuf.appendString("t", field: 1, to: &meta)
        Protobuf.appendBytes(meta, field: 2, to: &response)
        let body = NvidiaSpeech.frame(response) + NvidiaSpeech.frame(Data())
        let messages = NvidiaSpeech.messages(inBody: body)
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages.flatMap { NvidiaSpeech.audio(fromResponse: $0[0]) }, Data([1, 2, 3, 4]))
        XCTAssertNil(NvidiaSpeech.messages(inBody: body.dropLast(1)))
        XCTAssertNil(NvidiaSpeech.messages(inBody: Data([1, 0, 0, 0, 0]))) // compressed
        XCTAssertEqual(NvidiaSpeech.messages(inBody: Data()), [])
        // A large message: the length is big-endian.
        let big = Data(repeating: 7, count: 70_000)
        XCTAssertEqual(NvidiaSpeech.messages(inBody: NvidiaSpeech.frame(big))?.first?.count, 70_000)
    }

    func testErrors() {
        XCTAssertNil(NvidiaSpeech.error(inHeaders: ["grpc-status": "0"]))
        XCTAssertNil(NvidiaSpeech.error(inHeaders: [:]))
        XCTAssertEqual(NvidiaSpeech.error(inHeaders: ["Grpc-Status": "16", "grpc-message": "Unauthorized%20key"]),
                       "gRPC status 16: Unauthorized key")
    }

    func testFunctionID() {
        let json = Data(#"""
        {"functions":[{"id":"old","name":"ai-magpie-tts-multilingual","status":"INACTIVE"},
                      {"id":"new","name":"ai-magpie-tts-multilingual","status":"ACTIVE"},
                      {"id":"x","name":"other","status":"ACTIVE"}]}
        """#.utf8)
        XCTAssertEqual(NvidiaSpeech.functionID(in: json), "new")
        XCTAssertNil(NvidiaSpeech.functionID(in: json, name: "missing"))
        XCTAssertNil(NvidiaSpeech.functionID(in: Data("[]".utf8)))
    }

    func testVoicesFromConfig() {
        func entry(_ key: String, _ value: String) -> Data {
            var data = Data()
            Protobuf.appendString(key, field: 1, to: &data)
            Protobuf.appendString(value, field: 2, to: &data)
            return data
        }
        var config = Data()
        Protobuf.appendString("magpie", field: 1, to: &config)
        Protobuf.appendBytes(entry("voice_name", "Magpie-Multilingual"), field: 2, to: &config)
        Protobuf.appendBytes(entry("subvoices", "JA-JP.Ray:0,JA-JP.Isabela:1,EN-US.Aria.Calm:2"), field: 2, to: &config)
        var reply = Data()
        Protobuf.appendBytes(config, field: 1, to: &reply)
        XCTAssertEqual(NvidiaSpeech.voices(fromConfig: reply), [
            "Magpie-Multilingual.EN-US.Aria.Calm", "Magpie-Multilingual.JA-JP.Isabela", "Magpie-Multilingual.JA-JP.Ray",
        ])
    }

    func testPieces() {
        XCTAssertEqual(NvidiaSpeech.pieces("短い。"), ["短い。"])
        let long = String(repeating: "あ", count: 8) + "。" + String(repeating: "い", count: 8) + "。"
        XCTAssertEqual(NvidiaSpeech.pieces(long, limit: 12), [String(repeating: "あ", count: 8) + "。", String(repeating: "い", count: 8) + "。"])
        XCTAssertEqual(NvidiaSpeech.pieces("aaaa bbbb cccc", limit: 6), ["aaaa", "bbbb", "cccc"])
        XCTAssertEqual(NvidiaSpeech.pieces(String(repeating: "x", count: 10), limit: 4), ["xxxx", "xxxx", "xx"])
        XCTAssertEqual(NvidiaSpeech.pieces("  \n "), [])
    }
}
