import CryptoKit
import Security
import XCTest
@testable import CmdsCore

final class SyncSecurityTests: XCTestCase {
    // MARK: - DER

    func testDERPrimitives() {
        XCTAssertEqual(DER.length(0), [0x00])
        XCTAssertEqual(DER.length(127), [0x7F])
        XCTAssertEqual(DER.length(128), [0x81, 0x80])
        XCTAssertEqual(DER.length(300), [0x82, 0x01, 0x2C])
        XCTAssertEqual(DER.integer(0), [0x02, 0x01, 0x00])
        XCTAssertEqual(DER.integer(2), [0x02, 0x01, 0x02])
        XCTAssertEqual(DER.integer(255), [0x02, 0x02, 0x00, 0xFF])
        XCTAssertEqual(DER.integer(unsigned: [0x00, 0x00, 0x7F, 0x01]), [0x02, 0x02, 0x7F, 0x01])
        XCTAssertEqual(DER.objectIdentifier("1.2.840.10045.2.1"), [0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
        XCTAssertEqual(DER.objectIdentifier("2.5.29.19"), [0x06, 0x03, 0x55, 0x1D, 0x13])
        XCTAssertEqual(DER.boolean(true), [0x01, 0x01, 0xFF])
        XCTAssertEqual(DER.bitString([0x80], unusedBits: 7), [0x03, 0x02, 0x07, 0x80])
        XCTAssertEqual(DER.sequence([]), [0x30, 0x00])
        XCTAssertEqual(DER.set([[0x02, 0x01, 0x05], [0x02, 0x01, 0x01]]), [0x31, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x05])
        XCTAssertEqual(DER.explicit(0, DER.integer(2)), [0xA0, 0x03, 0x02, 0x01, 0x02])
        XCTAssertEqual(DER.utf8String("é"), [0x0C, 0x02, 0xC3, 0xA9])
        XCTAssertEqual(DER.tlv(tag: 0x04, Array(repeating: 0, count: 200)).prefix(3), [0x04, 0x81, 0xC8])
    }

    func testDERTimeSwitchesToGeneralizedTimeIn2050() {
        let utc = Date(timeIntervalSince1970: 1_793_000_000) // 2026-10-26 07:33:20 UTC
        XCTAssertEqual(DER.time(utc), [0x17, 0x0D] + Array("261026073320Z".utf8))
        let later = Date(timeIntervalSince1970: 2_556_143_999) // 2050-12-31 23:59:59 UTC
        XCTAssertEqual(DER.time(later), [0x18, 0x0F] + Array("20501231235959Z".utf8))
    }

    // MARK: - Certificate

    func testSelfSignedCertificateParsesAndVerifies() throws {
        let key = P256.Signing.PrivateKey()
        let publicKey = key.publicKey.x963Representation
        let notBefore = Date().addingTimeInterval(-60)
        let der = try SyncCertificate.make(commonName: "cmds Test Mac", publicKey: publicKey,
                                           serialNumber: SyncCertificate.randomSerialNumber(),
                                           notBefore: notBefore, notAfter: notBefore + SyncCertificate.validity) { tbs in
            try key.signature(for: tbs).derRepresentation
        }

        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        XCTAssertEqual(SecCertificateCopySubjectSummary(certificate) as String?, "cmds Test Mac")
        let parsedKey = try XCTUnwrap(SecCertificateCopyKey(certificate))
        XCTAssertEqual(SecKeyCopyExternalRepresentation(parsedKey, nil) as Data?, publicKey)

        // Self-signed: the signature checks out with its own key, and it is a valid chain when anchored to itself.
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust), errSecSuccess)
        let secTrust = try XCTUnwrap(trust)
        SecTrustSetAnchorCertificates(secTrust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(secTrust, true)
        var error: CFError?
        XCTAssertTrue(SecTrustEvaluateWithError(secTrust, &error), "\(String(describing: error))")

        // The fingerprint the phone pins is the SHA-256 of exactly these bytes.
        XCTAssertEqual(SyncTLS.leafFingerprint(of: secTrust), SyncFingerprint(certificate: der))
        XCTAssertEqual(SyncFingerprint(certificate: der).bytes, Data(SHA256.hash(data: der)))
    }

    func testCertificateRejectsBadInput() {
        let key = P256.Signing.PrivateKey()
        XCTAssertThrowsError(try SyncCertificate.make(commonName: "x", publicKey: key.publicKey.rawRepresentation,
                                                      serialNumber: [1], notBefore: Date(), notAfter: Date()) { _ in Data() }) {
            XCTAssertEqual($0 as? SyncCertificate.BuildError, .invalidPublicKey)
        }
        XCTAssertThrowsError(try SyncCertificate.make(commonName: "x", publicKey: key.publicKey.x963Representation,
                                                      serialNumber: [1], notBefore: Date(), notAfter: Date()) { _ in Data([1, 2, 3]) }) {
            XCTAssertEqual($0 as? SyncCertificate.BuildError, .invalidSignature)
        }
    }

    func testSerialNumberAndCommonName() {
        for _ in 0..<50 {
            let serial = SyncCertificate.randomSerialNumber()
            XCTAssertEqual(serial.count, 16)
            XCTAssertTrue((0x01...0x7F).contains(serial[0]))
            XCTAssertEqual(DER.integer(unsigned: serial).count, 18)
        }
        XCTAssertEqual(SyncCertificate.commonName(macName: "Ryo’s MacBook Pro"), "cmds Ryo’s MacBook Pro")
        XCTAssertEqual(SyncCertificate.commonName(macName: String(repeating: "m", count: 100)).count, 64)
    }

    // MARK: - Fingerprint

    func testFingerprintForms() throws {
        let fingerprint = try XCTUnwrap(SyncFingerprint(bytes: Data([0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6] + Array(repeating: 0x07, count: 26))))
        XCTAssertEqual(fingerprint.short, "A1B2-C3D4-E5F6")
        XCTAssertEqual(fingerprint.base64url.count, 43)
        XCTAssertEqual(SyncFingerprint(base64url: fingerprint.base64url), fingerprint)
        XCTAssertTrue(fingerprint.hex.hasPrefix("A1:B2:C3:D4:E5:F6:07"))
        XCTAssertEqual(fingerprint.hex.count, 32 * 3 - 1)

        XCTAssertNil(SyncFingerprint(bytes: Data(count: 31)))
        XCTAssertNil(SyncFingerprint(base64url: fingerprint.base64url + "="))
        XCTAssertNil(SyncFingerprint(base64url: String(fingerprint.base64url.dropLast())))
        XCTAssertNil(SyncFingerprint(base64url: "+" + fingerprint.base64url.dropFirst()))
        XCTAssertNil(SyncFingerprint(base64url: ""))
        // 43 characters carry 258 bits; the last character's two low bits must be zero (one canonical form).
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var chars = Array(fingerprint.base64url)
        let last = try XCTUnwrap(alphabet.firstIndex(of: chars[42]))
        XCTAssertEqual(last % 4, 0)
        chars[42] = alphabet[last + 1]
        XCTAssertNil(SyncFingerprint(base64url: String(chars)))

        let json = try JSONEncoder().encode([fingerprint])
        XCTAssertEqual(String(decoding: json, as: UTF8.self), "[\"\(fingerprint.base64url)\"]")
        XCTAssertEqual(try JSONDecoder().decode([SyncFingerprint].self, from: json), [fingerprint])
        XCTAssertThrowsError(try JSONDecoder().decode([SyncFingerprint].self, from: Data(#"["abc"]"#.utf8)))
    }

    func testBase64URL() {
        XCTAssertEqual(Base64URL.encode(Data([0xFB, 0xFF])), "-_8")
        XCTAssertEqual(Base64URL.decode("-_8"), Data([0xFB, 0xFF]))
        XCTAssertNil(Base64URL.decode("-_9")) // non-canonical trailing bits
        XCTAssertNil(Base64URL.decode("a"))
        XCTAssertNil(Base64URL.decode("ab=="))
        XCTAssertEqual(Base64URL.decode(""), Data())
    }

    // MARK: - Pin comparison

    func testPinPolicy() throws {
        let pinned = SyncFingerprint(certificate: Data("mac".utf8))
        let other = SyncFingerprint(certificate: Data("impostor".utf8))
        let samePinned = try XCTUnwrap(SyncFingerprint(base64url: pinned.base64url))
        XCTAssertTrue(pinned.matches(samePinned))
        XCTAssertFalse(pinned.matches(other))

        XCTAssertTrue(SyncTLS.evaluate(presented: samePinned, policy: .pinned(pinned)))
        XCTAssertFalse(SyncTLS.evaluate(presented: other, policy: .pinned(pinned)))
        XCTAssertFalse(SyncTLS.evaluate(presented: nil, policy: .pinned(pinned)))
        // A probe only reads the fingerprint; it never lets a handshake finish.
        XCTAssertFalse(SyncTLS.evaluate(presented: pinned, policy: .probe))
        XCTAssertFalse(SyncTLS.evaluate(presented: nil, policy: .probe))
    }

    // MARK: - QR payload

    func testPairingPayloadRoundTrip() throws {
        let fingerprint = SyncFingerprint(certificate: Data("cert".utf8))
        let payload = SyncPairingPayload(name: "Ryo’s MacBook Pro & co=1", host: "192.168.1.23", port: 47823,
                                         fingerprint: fingerprint, code: "042917")
        let uri = payload.uri
        XCTAssertTrue(uri.hasPrefix("cmds-pair:v2?name=Ryo%E2%80%99s%20MacBook%20Pro%20%26%20co%3D1&host=192.168.1.23&port=47823&fp="))
        XCTAssertTrue(uri.hasSuffix("&code=042917"))
        XCTAssertEqual(try SyncPairingPayload.parse(uri), payload)
        XCTAssertEqual(try SyncPairingPayload.parse("  \(uri)\n"), payload)

        let noName = SyncPairingPayload(name: nil, host: "Ryos-Mac.local", port: 1, fingerprint: fingerprint, code: "000000")
        XCTAssertFalse(noName.uri.contains("name="))
        XCTAssertEqual(try SyncPairingPayload.parse(noName.uri), noName)

        let v6 = SyncPairingPayload(name: "m", host: "fe80::1%en0", port: 47823, fingerprint: fingerprint, code: "123456")
        XCTAssertEqual(try SyncPairingPayload.parse(v6.uri), v6)

        // Scheme is case-insensitive; unknown keys and their order do not matter.
        let shuffled = "CMDS-PAIR:v2?code=042917&future=x&fp=\(fingerprint.base64url)&port=47823&host=192.168.1.23"
        XCTAssertEqual(try SyncPairingPayload.parse(shuffled),
                       SyncPairingPayload(name: nil, host: "192.168.1.23", port: 47823, fingerprint: fingerprint, code: "042917"))
    }

    func testPairingPayloadRejectsBadInput() {
        let fp = SyncFingerprint(certificate: Data("cert".utf8)).base64url
        let good = "cmds-pair:v2?host=10.0.0.2&port=47823&fp=\(fp)&code=123456"
        XCTAssertNoThrow(try SyncPairingPayload.parse(good))

        func error(_ text: String) -> SyncPairingPayload.ParseError? {
            do {
                _ = try SyncPairingPayload.parse(text)
                return nil
            } catch {
                return error as? SyncPairingPayload.ParseError
            }
        }
        XCTAssertEqual(error("https://example.com"), .notPairingPayload)
        XCTAssertEqual(error(""), .notPairingPayload)
        XCTAssertEqual(error(good + String(repeating: "x", count: 2000)), .notPairingPayload)
        XCTAssertEqual(error("cmds-pair:v1?host=10.0.0.2&port=47823&code=123456"), .unsupportedVersion("v1"))
        XCTAssertEqual(error("cmds-pair:v2?port=47823&fp=\(fp)&code=123456"), .missingField("host"))
        XCTAssertEqual(error("cmds-pair:v2?host=10.0.0.2&port=47823&code=123456"), .missingField("fp"))
        XCTAssertEqual(error("cmds-pair:v2?host=10.0.0.2&port=47823&fp=\(fp)"), .missingField("code"))
        XCTAssertEqual(error(good.replacingOccurrences(of: "code=123456", with: "code=12345")), .invalidField("code"))
        XCTAssertEqual(error(good.replacingOccurrences(of: "code=123456", with: "code=12345%EF%BC%96")), .invalidField("code"))
        XCTAssertEqual(error(good.replacingOccurrences(of: "port=47823", with: "port=0")), .invalidField("port"))
        XCTAssertEqual(error(good.replacingOccurrences(of: "port=47823", with: "port=70000")), .invalidField("port"))
        XCTAssertEqual(error(good.replacingOccurrences(of: "fp=\(fp)", with: "fp=\(fp.dropLast(2))")), .invalidField("fp"))
        XCTAssertEqual(error(good.replacingOccurrences(of: "10.0.0.2", with: "evil.example%2Fpath")), .invalidField("host"))
        XCTAssertEqual(error(good.replacingOccurrences(of: "10.0.0.2", with: "user%40host")), .invalidField("host"))
        XCTAssertEqual(error(good + "&code=654321"), .invalidField("code"))
        XCTAssertEqual(error(good + "&name=a%0Ab"), .invalidField("name"))
        XCTAssertEqual(error(good + "&name=" + String(repeating: "n", count: 64)), .invalidField("name"))
        XCTAssertEqual(error(good + "&broken%ZZ=1"), .invalidField("broken%ZZ=1"))
    }

    // MARK: - Environment switches (isolated test instances)

    func testSyncEnvironmentSwitches() {
        XCTAssertEqual(CmdsEnv.syncPortSetting(environment: [:]), .unset)
        XCTAssertEqual(CmdsEnv.syncPortSetting(environment: ["CMDS_SYNC_PORT": " "]), .unset)
        XCTAssertEqual(CmdsEnv.syncPortSetting(environment: ["CMDS_SYNC_PORT": "47999"]), .port(47999))
        XCTAssertEqual(CmdsEnv.syncPortSetting(environment: ["CMDS_SYNC_PORT": "0"]), .invalid("0"))
        XCTAssertEqual(CmdsEnv.syncPortSetting(environment: ["CMDS_SYNC_PORT": "70000"]), .invalid("70000"))
        XCTAssertEqual(CmdsEnv.syncPortSetting(environment: ["CMDS_SYNC_PORT": "port"]), .invalid("port"))
        XCTAssertTrue(CmdsEnv.isBonjourDisabled(environment: ["CMDS_SYNC_NO_BONJOUR": "1"]))
        XCTAssertTrue(CmdsEnv.isBonjourDisabled(environment: ["CMDS_SYNC_NO_BONJOUR": "yes"]))
        XCTAssertFalse(CmdsEnv.isBonjourDisabled(environment: ["CMDS_SYNC_NO_BONJOUR": "0"]))
        XCTAssertFalse(CmdsEnv.isBonjourDisabled(environment: [:]))
    }

    // MARK: - Protocol

    func testVersionAndTXTRecord() {
        XCTAssertEqual(SyncProtocol.version, 2)
        XCTAssertEqual(ClientMessage.Hello(deviceName: "d").protocolVersion, 2)
        let v1 = ClientMessage.Hello(protocolVersion: 1, deviceName: "d", pairingCode: "123456")
        guard case .rejected(let info) = PairingAuthenticator.evaluate(v1, currentCode: "123456", knownTokens: []) else {
            return XCTFail("a v1 hello must be rejected")
        }
        XCTAssertEqual(info.code, .unsupportedVersion)

        let fingerprint = SyncFingerprint(certificate: Data("cert".utf8))
        XCTAssertEqual(SyncProtocol.txtRecord(macName: "Mac"), ["name": "Mac", "version": "2"])
        XCTAssertEqual(SyncProtocol.txtRecord(macName: "Mac", fingerprint: fingerprint),
                       ["name": "Mac", "version": "2", "fp": fingerprint.base64url])
    }
}
