import CmdsCore
@preconcurrency import CoreBluetooth
import Foundation
import Network

/// Bluetooth fallback for the iOS companion (docs/internals/sync-protocol.md "Bluetooth"): a CoreBluetooth peripheral that
/// advertises `SyncBluetooth.serviceUUID`, publishes an encrypted L2CAP channel and relays every opened
/// channel, byte for byte, to the sync listener on 127.0.0.1. The sync server therefore sees an ordinary
/// TLS client and applies every check it applies to network clients; the phone authenticates the Mac by
/// its pinned certificate, never by Bluetooth.
///
/// Runs while the sync listener is up and "Allow Bluetooth Sync" is on, unless `CMDS_SYNC_NO_BLUETOOTH` is
/// set. Relayed connections are tagged per Bluetooth peer (`SyncServer.relayedPeer(of:)`), so rate limits and
/// lockouts keep working per phone.
@MainActor
final class SyncBluetoothPeripheral: NSObject {
    static let shared = SyncBluetoothPeripheral()
    static let enabledDefaultsKey = "SyncBluetoothEnabled"
    /// Open channels at most (the sync server has its own, lower per-peer limits).
    static let maxChannels = 8

    private(set) var status = LocalizedStatus("Off")
    /// English, for the API and CLI; the UI shows `status.localized`.
    var statusText: String { status.english }

    private var manager: CBPeripheralManager?
    private var psm: CBL2CAPPSM?
    private var service: CBMutableService?
    private var publishedInfo: SyncBluetooth.Info?
    private var relays: [UUID: SyncStreamRelay] = [:]
    /// Channels whose relay is still being set up (they count against `maxChannels`).
    private var settingUp = 0
    private var observer: NSObjectProtocol?
    /// After a failed publish, service or advertising (#343): the next try, and how many failed in a row.
    private var retry: DispatchWorkItem?
    private var failures = 0
    /// Seconds before trying again after the 1st, 2nd, 3rd… failure in a row (the last one repeats).
    static let retryDelays: [Int] = [5, 15, 60, 300]

    private override init() {
        super.init()
        UserDefaults.standard.register(defaults: [Self.enabledDefaultsKey: true])
    }

    /// "Allow Bluetooth Sync" (menu). On by default; only takes effect while sync runs.
    var isAllowed: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledDefaultsKey)
            reconcile()
        }
    }

    /// Whether the menu toggle can apply (sync enabled and not switched off by the environment).
    var isAvailable: Bool {
        SyncServer.shared.isEnabled && !CmdsEnv.isSyncDisabled() && !CmdsEnv.isBluetoothDisabled()
    }

    /// Starts following the sync server (call once at launch).
    func activate() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .syncServerDidChange, object: SyncServer.shared,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        reconcile()
    }

    /// Peripheral state for `sync.status`. Reading `CBManager.authorization` never prompts.
    var report: SyncStatusReport.Bluetooth {
        let authorization: String
        switch CBManager.authorization {
        case .allowedAlways: authorization = "allowedAlways"
        case .denied: authorization = "denied"
        case .restricted: authorization = "restricted"
        case .notDetermined: authorization = "notDetermined"
        @unknown default: authorization = "unknown"
        }
        let state: String
        switch manager?.state {
        case nil: state = "off"
        case .poweredOn?: state = "poweredOn"
        case .poweredOff?: state = "poweredOff"
        case .unauthorized?: state = "unauthorized"
        case .unsupported?: state = "unsupported"
        case .resetting?: state = "resetting"
        case .unknown?: state = "unknown"
        @unknown default: state = "unknown"
        }
        return SyncStatusReport.Bluetooth(allowed: isAllowed, disabledByEnvironment: CmdsEnv.isBluetoothDisabled(),
                                          authorization: authorization, managerState: state,
                                          advertising: manager?.isAdvertising ?? false, psm: psm,
                                          channels: relays.count, status: statusText)
    }

    // MARK: - Lifecycle

    /// What should be advertised now, or nil when Bluetooth sync should be off.
    private var wantedInfo: SyncBluetooth.Info? {
        let server = SyncServer.shared
        guard isAllowed, !CmdsEnv.isBluetoothDisabled(), server.port != nil, let identity = server.identity else { return nil }
        return SyncBluetooth.Info(psm: psm ?? 0, fingerprint: identity.fingerprint, name: server.macName)
    }

    private func reconcile() {
        guard let wanted = wantedInfo else {
            if manager != nil { stop() }
            return
        }
        guard let manager else {
            status = LocalizedStatus("Starting…")
            // Creating the manager asks for Bluetooth permission the first time.
            manager = CBPeripheralManager(delegate: self, queue: .main,
                                          options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
            return
        }
        // Identity reset or new Mac name: publish the new hint.
        if manager.state == .poweredOn, psm != nil, let published = publishedInfo, published != wanted {
            publishService()
        }
    }

    private func stop() {
        cancelRetry()
        if let manager {
            manager.stopAdvertising()
            manager.removeAllServices()
            if let psm { manager.unpublishL2CAPChannel(psm) }
            manager.delegate = nil
        }
        manager = nil
        psm = nil
        service = nil
        publishedInfo = nil
        // Relays still being set up see `manager == nil` and close themselves.
        for relay in relays.values { relay.close() }
        relays.removeAll()
        status = LocalizedStatus("Off")
    }

    private func publishService() {
        guard let manager, let psm, var info = wantedInfo else { return }
        info.psm = psm
        manager.stopAdvertising()
        if let service { manager.remove(service) }
        // Readable without pairing, like the Bonjour TXT record: hints only, nothing secret.
        let characteristic = CBMutableCharacteristic(type: CBUUID(string: SyncBluetooth.infoCharacteristicUUID),
                                                     properties: .read, value: info.encoded, permissions: .readable)
        let service = CBMutableService(type: CBUUID(string: SyncBluetooth.serviceUUID), primary: true)
        service.characteristics = [characteristic]
        self.service = service
        publishedInfo = info
        manager.add(service)
    }

    // MARK: - Channels

    private func open(_ channel: CBL2CAPChannel) {
        guard relays.count + settingUp < Self.maxChannels, let port = SyncServer.shared.port else {
            syncLog.notice("bluetooth: refusing channel (\(self.relays.count, privacy: .public) open)")
            channel.inputStream?.close()
            channel.outputStream?.close()
            return
        }
        guard let input = channel.inputStream, let output = channel.outputStream else {
            syncLog.error("bluetooth: refusing channel without streams")
            channel.inputStream?.close()
            channel.outputStream?.close()
            return
        }
        let id = UUID()
        // Per-peer label for the sync server's limits; CBCentral identifiers are stable per phone.
        let peer = SyncBluetooth.peerHostPrefix + channel.peer.identifier.uuidString.prefix(8).lowercased()
        let streams = (input: input, output: output)
        settingUp += 1
        // Connecting is blocking (loopback, immediate); keep it off the main thread anyway.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let socket: Int32
            let release: @Sendable () -> Void
            do {
                (socket, release) = try SyncServer.connectRelay(port: port, peer: peer)
            } catch {
                syncLog.error("bluetooth: cannot reach the sync listener: \(String(describing: error), privacy: .public)")
                streams.input.close()
                streams.output.close()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.settingUp -= 1 }
                }
                return
            }
            let relay = SyncStreamRelay(streams, SyncLoopback.streams(socket: socket), anchors: [channel]) {
                release()

                DispatchQueue.main.async {
                    MainActor.assumeIsolated { _ = self?.relays.removeValue(forKey: id) }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.settingUp -= 1
                    guard let self, self.manager != nil else {
                        relay.start()
                        return relay.close()
                    }
                    self.relays[id] = relay
                    relay.start()
                    syncLog.notice("bluetooth: relaying \(peer, privacy: .public)")
                }
            }
        }
    }
}

extension SyncBluetoothPeripheral {
    /// Publishes the L2CAP channel, else (it is published) the service, which then advertises.
    private func start(_ peripheral: CBPeripheralManager) {
        retry?.cancel()
        retry = nil
        if psm == nil {
            // No link encryption: an encrypted channel needs a Bluetooth bond, whose pairing prompt fails
            // silently on the phone ("Unknown error" from openL2CAPChannel, seen on a real iPhone). The
            // channel only carries the pinned TLS stream, which is where trust and secrecy come from.
            peripheral.publishL2CAPChannel(withEncryption: false)
        } else {
            publishService()
        }
    }

    /// No more tries: stopped, or Bluetooth went off (it starts over when it comes back).
    private func cancelRetry() {
        retry?.cancel()
        retry = nil
        failures = 0
    }

    /// A publish, service or advertising failure (e.g. "No resources available for L2CAP"): tries again later
    /// (`retryDelays`) instead of staying off until Bluetooth or cmds restarts (#343).
    private func failed(_ error: Error) {
        let delay = Self.retryDelays[min(failures, Self.retryDelays.count - 1)]
        failures += 1
        status = LocalizedStatus("Failed: \(error.localizedDescription). Trying again in \(delay) s.")
        retry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let manager = self.manager, manager.state == .poweredOn else { return }
                self.retry = nil
                self.status = LocalizedStatus("Starting…")
                self.start(manager)
            }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay), execute: work)
    }
}

extension SyncBluetoothPeripheral: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated {
            guard peripheral === manager else { return }
            switch peripheral.state {
            case .poweredOn:
                status = LocalizedStatus("Starting…")
                start(peripheral)
            case .unauthorized:
                status = LocalizedStatus("Not allowed (System Settings › Privacy & Security › Bluetooth)")
            case .unsupported:
                status = LocalizedStatus("Not supported on this Mac")
            case .poweredOff:
                status = LocalizedStatus("Bluetooth is off")
                // L2CAP channel, services and relays are gone; start over when it comes back.
                cancelRetry()
                psm = nil
                service = nil
                publishedInfo = nil
                for relay in relays.values { relay.close() }
                relays.removeAll()
            default:
                status = LocalizedStatus("Unavailable")
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === manager else { return }
            if let error {
                syncLog.error("bluetooth: L2CAP publish failed: \(error.localizedDescription, privacy: .public)")
                return failed(error)
            }
            psm = PSM
            publishService()
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === manager, service === self.service else { return }
            if let error {
                syncLog.error("bluetooth: adding the service failed: \(error.localizedDescription, privacy: .public)")
                return failed(error)
            }
            peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: SyncBluetooth.serviceUUID)],
                                         CBAdvertisementDataLocalNameKey: "cmds"])
        }
    }

    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === manager else { return }
            if let error {
                syncLog.error("bluetooth: advertising failed: \(error.localizedDescription, privacy: .public)")
                failed(error)
            } else {
                failures = 0
                status = LocalizedStatus("Advertising (PSM \(psm.map(String.init) ?? "?"))")
                syncLog.notice("bluetooth: advertising, PSM \(self.psm ?? 0, privacy: .public)")
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === manager else { return }
            guard let channel, error == nil else {
                syncLog.notice("bluetooth: channel failed: \(error?.localizedDescription ?? "-", privacy: .public)")
                return
            }
            open(channel)
        }
    }
}
