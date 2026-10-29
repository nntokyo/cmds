import CmdsCore
import Foundation

extension SyncStatusReport {
    /// Current state of iOS sync for the socket API's `sync.status` (local socket only).
    @MainActor
    static func current() -> SyncStatusReport {
        let server = SyncServer.shared
        let remote = SyncRemoteAccess.shared
        return SyncStatusReport(
            enabled: server.isEnabled,
            state: server.statusText,
            port: server.port,
            fingerprint: server.identity?.fingerprint.short,
            bonjour: Bonjour(enabled: server.port != nil && !CmdsEnv.isBonjourDisabled(), serviceName: server.serviceName),
            pairingWindowOpen: server.isPairingOpen,
            pairedDevices: server.store.devices.count,
            bluetooth: SyncBluetoothPeripheral.shared.report,
            remote: Remote(enabled: remote.settings.enabled, host: remote.settings.host,
                           relayPort: remote.settings.relayPort, forwarding: remote.isForwarding, status: remote.statusText),
            clients: server.clientReports)
    }
}
