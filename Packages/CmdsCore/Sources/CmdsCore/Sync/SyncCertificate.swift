import CryptoKit
import Foundation

/// Self-signed X.509 v3 certificate for the Mac's sync identity: ECDSA P-256 key, ecdsa-with-SHA256
/// signature, CN "cmds <Mac name>", end-entity TLS server certificate. Built here (DER by hand) so no
/// third-party ASN.1 code is needed; the private key stays with the caller, which only signs the
/// to-be-signed bytes. Nobody validates it against a CA: the phone pins its SHA-256 (`SyncFingerprint`).
public enum SyncCertificate {
    public enum BuildError: Error, Equatable {
        /// The public key is not an uncompressed P-256 point (65 bytes, 0x04 || X || Y).
        case invalidPublicKey
        /// The signer returned something other than a DER `Ecdsa-Sig-Value`.
        case invalidSignature
    }

    static let ecPublicKeyOID = "1.2.840.10045.2.1"
    static let prime256v1OID = "1.2.840.10045.3.1.7"
    static let ecdsaWithSHA256OID = "1.2.840.10045.4.3.2"
    static let commonNameOID = "2.5.4.3"

    /// How long a new identity is valid. Pinning does not depend on it; it only has to outlive the pairing.
    public static let validity: TimeInterval = 20 * 365 * 24 * 60 * 60

    /// Builds the DER certificate.
    /// - Parameters:
    ///   - publicKey: uncompressed P-256 point, e.g. from `SecKeyCopyExternalRepresentation`.
    ///   - serialNumber: positive serial, at most 20 bytes (`randomSerialNumber()`).
    ///   - sign: ECDSA with SHA-256 over the given bytes, returning the DER `Ecdsa-Sig-Value`
    ///     (`SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, …)`).
    public static func make(commonName: String, publicKey: Data, serialNumber: [UInt8],
                            notBefore: Date, notAfter: Date, sign: (Data) throws -> Data) throws -> Data {
        let tbs = try tbsCertificate(commonName: commonName, publicKey: publicKey, serialNumber: serialNumber,
                                     notBefore: notBefore, notAfter: notAfter)
        let signature = try sign(Data(tbs))
        // SEQUENCE { INTEGER r, INTEGER s }: at least 8 bytes, at most 72 for P-256.
        guard (8...72).contains(signature.count), signature.first == 0x30 else { throw BuildError.invalidSignature }
        return Data(DER.sequence([tbs, signatureAlgorithm, DER.bitString(Array(signature))]))
    }

    /// The DER `TBSCertificate` that `make` signs.
    public static func tbsCertificate(commonName: String, publicKey: Data, serialNumber: [UInt8],
                                      notBefore: Date, notAfter: Date) throws -> [UInt8] {
        guard publicKey.count == 65, publicKey.first == 0x04 else { throw BuildError.invalidPublicKey }
        let name = DER.sequence([
            DER.set([DER.sequence([DER.objectIdentifier(commonNameOID), DER.utf8String(commonName)])]),
        ])
        let subjectPublicKeyInfo = DER.sequence([
            DER.sequence([DER.objectIdentifier(ecPublicKeyOID), DER.objectIdentifier(prime256v1OID)]),
            DER.bitString(Array(publicKey)),
        ])
        let keyIdentifier = Array(Insecure.SHA1.hash(data: publicKey))
        let extensions = DER.explicit(3, DER.sequence([
            // basicConstraints: not a CA.
            extensionField("2.5.29.19", critical: true, DER.sequence([])),
            // keyUsage: digitalSignature (bit 0).
            extensionField("2.5.29.15", critical: true, DER.bitString([0x80], unusedBits: 7)),
            // extKeyUsage: serverAuth.
            extensionField("2.5.29.37", critical: false, DER.sequence([DER.objectIdentifier("1.3.6.1.5.5.7.3.1")])),
            // subjectKeyIdentifier: SHA-1 of the public key (RFC 5280 method 1).
            extensionField("2.5.29.14", critical: false, DER.octetString(keyIdentifier)),
        ]))
        return DER.sequence([
            DER.explicit(0, DER.integer(2)), // v3
            DER.integer(unsigned: serialNumber),
            signatureAlgorithm,
            name, // issuer = subject (self-signed)
            DER.sequence([DER.time(notBefore), DER.time(notAfter)]),
            name,
            subjectPublicKeyInfo,
            extensions,
        ])
    }

    /// AlgorithmIdentifier for ecdsa-with-SHA256 (parameters absent, RFC 5758).
    static var signatureAlgorithm: [UInt8] {
        DER.sequence([DER.objectIdentifier(ecdsaWithSHA256OID)])
    }

    static func extensionField(_ oid: String, critical: Bool, _ value: [UInt8]) -> [UInt8] {
        DER.sequence([DER.objectIdentifier(oid)] + (critical ? [DER.boolean(true)] : []) + [DER.octetString(value)])
    }

    /// Random positive 16-byte serial number (first byte 0x01...0x7F, so it encodes in exactly 16 bytes).
    public static func randomSerialNumber() -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        var bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        bytes[0] = (bytes[0] & 0x7F) | 0x01
        return bytes
    }

    /// "cmds <Mac name>", at most 64 characters (X.520 upper bound for a common name).
    public static func commonName(macName: String) -> String {
        String("cmds \(macName)".prefix(64))
    }
}
