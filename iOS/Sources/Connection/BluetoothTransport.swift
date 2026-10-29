import CmdsCore
@preconcurrency import CoreBluetooth
import Foundation

/// Bluetooth fallback (docs/SYNC.md "Bluetooth"): finds the paired Mac's cmds peripheral, opens its L2CAP
/// channel and relays a loopback TCP socket over it. The usual `WebSocketTransport` then connects to
/// `wss://127.0.0.1:<loopback port>/` with the same pinned-certificate check, so the Mac is authenticated
/// by TLS exactly as over Wi‑Fi and nothing is sent before the pin matched. Bluetooth itself is only a
/// pipe; the fingerprint hint in the peripheral's info characteristic just picks which Mac to try.
///
/// Only for pinned connections (manual pairing's identity probe needs the Mac's address).
/// Main thread only (`@unchecked Sendable` so the loopback accept can hop back to main).
final class BluetoothTransport: NSObject, SyncTransport, @unchecked Sendable {
    var onEvent: ((TransportEvent) -> Void)?
    var linkPath: SyncLinkPath { .bluetooth }

    private let pin: SyncFingerprint
    private let policy: SyncTLS.PeerPolicy
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    /// Peripherals that are not the pinned Mac (or failed); not tried again by this transport.
    private var rejected: Set<UUID> = []
    private var pendingServices = 0
    private var pendingReads = 0
    private var channelRequested = false
    /// CoreBluetooth never times out a connection: a candidate that does not get as far as the channel
    /// in this time is dropped and scanning resumes.
    private static let candidateTimeout: TimeInterval = 5
    private var candidateTimer: DispatchWorkItem?
    private var listener: SyncLoopback.Listener?
    private var relay: SyncStreamRelay?
    private var inner: WebSocketTransport?
    private var finished = false

    /// Progress for `ConnectionDiagnostics` (no identifiers or secrets).
    private func stage(_ text: String) {
        if !finished { ConnectionDiagnostics.shared.stage(.bluetooth, text) }
    }

    /// Nil unless `policy` pins a certificate.
    init?(policy: SyncTLS.PeerPolicy) {
        guard case .pinned(let pin) = policy else { return nil }
        self.pin = pin
        self.policy = policy
    }

    func start() {
        switch CBCentralManager.authorization {
        case .denied, .restricted:
            return fail(String(localized: "Bluetooth access is off for cmds (Settings › Privacy & Security › Bluetooth)."))
        default:
            break
        }
        // Creating the manager asks for Bluetooth permission the first time it is needed.
        stage("waiting for Bluetooth")
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func send(_ message: ClientMessage) {
        inner?.send(message)
    }

    func close() {
        guard !finished else { return }
        finished = true
        onEvent = nil
        teardown()
    }

    private func teardown() {
        candidateTimer?.cancel()
        candidateTimer = nil
        inner?.onEvent = nil
        inner?.close()
        inner = nil
        relay?.close()
        relay = nil
        listener?.close()
        listener = nil
        if let central {
            if central.state == .poweredOn { central.stopScan() }
            if let peripheral { central.cancelPeripheralConnection(peripheral) }
            central.delegate = nil
        }
        central = nil
        peripheral = nil
    }

    private func fail(_ reason: String) {
        guard !finished else { return }
        finished = true
        let handler = onEvent
        onEvent = nil
        teardown()
        handler?(.disconnected(reason: reason))
    }

    // MARK: - Discovery

    private func scan() {
        guard let central, central.state == .poweredOn, peripheral == nil else { return }
        stage(rejected.isEmpty ? "scanning" : "scanning (\(rejected.count) candidate(s) were not the paired Mac)")
        central.scanForPeripherals(withServices: [CBUUID(string: SyncBluetooth.serviceUUID)])
    }

    /// Not the pinned Mac (or unusable): drop it and keep scanning.
    private func reject(_ candidate: CBPeripheral) {
        rejected.insert(candidate.identifier)
        central?.cancelPeripheralConnection(candidate)
        guard candidate === peripheral, inner == nil else { return }
        candidateTimer?.cancel()
        candidateTimer = nil
        peripheral = nil
        pendingServices = 0
        pendingReads = 0
        channelRequested = false
        scan()
    }

    // MARK: - Relay

    private func startRelay(_ channel: CBL2CAPChannel) {
        guard let input = channel.inputStream, let output = channel.outputStream else {
            return fail(String(localized: "The Bluetooth channel to the Mac has no streams."))
        }
        let listener: SyncLoopback.Listener
        do {
            listener = try SyncLoopback.Listener()
        } catch {
            return fail("Bluetooth relay: \(error)")
        }
        self.listener = listener
        // The first local connection is ours (made right below); the listener then closes.
        listener.acceptOne { [weak self] socket in
            guard let socket else { return }
            let relay = SyncStreamRelay((input, output), SyncLoopback.streams(socket: socket), anchors: [channel])
            relay.start()
            DispatchQueue.main.async {
                guard let self, !self.finished else { return relay.close() }
                self.relay = relay
            }
        }
        let inner = WebSocketTransport(target: MacTarget(kind: .manual(host: "127.0.0.1", port: listener.port),
                                                         displayName: "Bluetooth"),
                                       policy: policy)
        self.inner = inner
        inner.onEvent = { [weak self] event in self?.forward(event) }
        inner.start()
    }

    private func forward(_ event: TransportEvent) {
        guard !finished else { return }
        switch event {
        case .connected, .message:
            onEvent?(event)
        case .identityPresented, .identityMismatch, .disconnected:
            finished = true
            let handler = onEvent
            onEvent = nil
            teardown()
            handler?(event)
        }
    }
}

extension BluetoothTransport: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        switch central.state {
        case .poweredOn: scan()
        case .poweredOff: fail(String(localized: "Bluetooth is off."))
        case .unauthorized: fail(String(localized: "Bluetooth access is off for cmds (Settings › Privacy & Security › Bluetooth)."))
        case .unsupported: fail(String(localized: "Bluetooth is not available on this device."))
        default: break // unknown, resetting: wait
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === self.central, self.peripheral == nil, !rejected.contains(peripheral.identifier) else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        stage("found peripheral, connecting")
        central.connect(peripheral)
        let timer = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral, peripheral === self.peripheral, !self.channelRequested, !self.finished else { return }
            self.reject(peripheral)
        }
        candidateTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.candidateTimeout, execute: timer)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        stage("connected peripheral, reading service info")
        peripheral.discoverServices([CBUUID(string: SyncBluetooth.serviceUUID)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        reject(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral, !finished else { return }
        if inner != nil {
            // The relay's streams end with the link; the TLS connection reports it. Make sure it does.
            relay?.close()
            if relay == nil { fail(String(localized: "The Bluetooth connection to the Mac was lost.")) }
        } else {
            reject(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        let services = (peripheral.services ?? []).filter { $0.uuid == CBUUID(string: SyncBluetooth.serviceUUID) }
        guard error == nil, !services.isEmpty else { return reject(peripheral) }
        // A Mac running several cmds instances shows one service per instance.
        pendingServices = services.count
        for service in services {
            peripheral.discoverCharacteristics([CBUUID(string: SyncBluetooth.infoCharacteristicUUID)], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral else { return }
        pendingServices -= 1
        for characteristic in service.characteristics ?? []
        where characteristic.uuid == CBUUID(string: SyncBluetooth.infoCharacteristicUUID) {
            pendingReads += 1
            peripheral.readValue(for: characteristic)
        }
        rejectIfExhausted(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic.uuid == CBUUID(string: SyncBluetooth.infoCharacteristicUUID) else { return }
        pendingReads -= 1
        if !channelRequested, error == nil, let value = characteristic.value,
           let info = SyncBluetooth.Info(encoded: value), info.matches(pin) {
            // A hint only: the pinned TLS handshake decides whether this is the Mac.
            channelRequested = true
            candidateTimer?.cancel()
            stage("opening L2CAP (PSM \(info.psm))")
            peripheral.openL2CAPChannel(CBL2CAPPSM(info.psm))
            return
        }
        rejectIfExhausted(peripheral)
    }

    private func rejectIfExhausted(_ peripheral: CBPeripheral) {
        if pendingServices <= 0, pendingReads <= 0, !channelRequested { reject(peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard peripheral === self.peripheral, !finished else { return }
        guard let channel, error == nil else {
            let reason = error?.localizedDescription ?? "-"
            return fail(String(localized: "Could not open the Bluetooth channel to the Mac (\(reason))."))
        }
        stage("L2CAP open, TLS handshake")
        startRelay(channel)
    }
}
