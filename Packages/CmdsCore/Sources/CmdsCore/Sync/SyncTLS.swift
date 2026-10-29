import Foundation
import Network
import Security

/// TLS for the sync connection, shared by the Mac (server) and the phone (client).
///
/// TLS 1.3 only. Session resumption and tickets are off on both sides, so every connection runs a full
/// handshake and the phone sees, and checks, the Mac's certificate each time. The phone never evaluates
/// the certificate against a CA: it accepts exactly one leaf certificate, the one whose SHA-256 it pinned
/// when pairing (`SyncFingerprint`). The TLS handshake itself proves the Mac holds that certificate's key.
public enum SyncTLS {
    /// How the phone decides about the certificate the Mac presents.
    public enum PeerPolicy: Equatable, Sendable {
        /// Accept only a leaf certificate with this fingerprint.
        case pinned(SyncFingerprint)
        /// Manual pairing: read the fingerprint, then refuse the handshake. Nothing is ever sent on such
        /// a connection; the user compares the fingerprint with the Mac before a pinned connection is made.
        case probe
    }

    /// Result of one certificate check, reported from the verify block before the handshake completes.
    public struct PeerCheck: Equatable, Sendable {
        /// Fingerprint of the leaf certificate the server presented (nil if there was none).
        public var presented: SyncFingerprint?
        /// Whether the handshake was allowed to continue.
        public var accepted: Bool

        public init(presented: SyncFingerprint?, accepted: Bool) {
            self.presented = presented
            self.accepted = accepted
        }
    }

    /// The verify block's decision (pure).
    public static func evaluate(presented: SyncFingerprint?, policy: PeerPolicy) -> Bool {
        guard let presented else { return false }
        switch policy {
        case .pinned(let pin): return presented.matches(pin)
        case .probe: return false
        }
    }

    /// Client (phone) options. `onCheck` runs on `queue` from the verify block, before the connection can
    /// become ready; with `.probe` it is the only way to learn the fingerprint.
    public static func clientOptions(policy: PeerPolicy, queue: DispatchQueue,
                                     onCheck: @escaping @Sendable (PeerCheck) -> Void) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let sec = options.securityProtocolOptions
        configure(sec)
        sec_protocol_options_set_verify_block(sec, { _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            let presented = leafFingerprint(of: trust)
            let accepted = evaluate(presented: presented, policy: policy)
            onCheck(PeerCheck(presented: presented, accepted: accepted))
            complete(accepted)
        }, queue)
        return options
    }

    /// Server (Mac) options presenting `identity`. Nil if Network.framework rejects the identity.
    public static func serverOptions(identity: SecIdentity) -> NWProtocolTLS.Options? {
        guard let secIdentity = sec_identity_create(identity) else { return nil }
        let options = NWProtocolTLS.Options()
        let sec = options.securityProtocolOptions
        configure(sec)
        sec_protocol_options_set_local_identity(sec, secIdentity)
        return options
    }

    private static func configure(_ sec: sec_protocol_options_t) {
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)
        sec_protocol_options_set_tls_resumption_enabled(sec, false)
        sec_protocol_options_set_tls_tickets_enabled(sec, false)
    }

    /// SHA-256 of the leaf (first) certificate of `trust`.
    public static func leafFingerprint(of trust: SecTrust) -> SyncFingerprint? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        return SyncFingerprint(certificate: SecCertificateCopyData(leaf) as Data)
    }
}
