import Foundation

/// Which saved Macs are the same Mac (the phone's `MacContinuity`, #325). The phone files what it keeps per Mac under
/// an id made from the Bonjour service name (`bonjour:<name>.<type>.<domain>`) or the address (`manual:<host>:<port>`);
/// the Mac itself is its pinned certificate fingerprint, which stays when those change.
public enum SyncMacContinuity {
    /// The ids of the saved Macs pinned to `fingerprint`, other than `id`, in the order given.
    public static func ids(sharing fingerprint: SyncFingerprint, in saved: [(id: String, fingerprint: SyncFingerprint)],
                           except id: String) -> [String] {
        saved.filter { $0.id != id && $0.fingerprint == fingerprint }.map(\.id)
    }

    /// The id is a Bonjour service name (replaced when the service is renamed), not an address.
    public static func isBonjourID(_ id: String) -> Bool { id.hasPrefix("bonjour:") }
}
