import Foundation

/// Result of the socket API method `sync.status` (`cmds sync`): what the iOS sync server, its Bluetooth
/// peripheral and the SSH remote-access tunnel are doing, and who is connected. Read-only and local-socket
/// only (not in `RemoteAPIPolicy.allowedMethods`). Holds no tokens, keys or pairing codes.
public struct SyncStatusReport: Codable, Equatable, Sendable {
    /// "Sync with iOS" is on (the menu setting; the environment may still keep it off, see `state`).
    public var enabled: Bool
    /// Server status as shown in the menu ("Listening on port 47823", "Disabled (CMDS_SYNC_DISABLED)", …).
    public var state: String
    /// TCP port the TLS WebSocket listener is bound to; nil while not listening.
    public var port: UInt16?
    /// Short fingerprint of the Mac's sync certificate (the hint shown in the pairing window); nil before
    /// the identity exists.
    public var fingerprint: String?
    public var bonjour: Bonjour
    public var pairingWindowOpen: Bool
    public var pairedDevices: Int
    public var bluetooth: Bluetooth
    public var remote: Remote
    public var clients: [Client]

    public struct Bonjour: Codable, Equatable, Sendable {
        /// Advertising is wanted (false with `CMDS_SYNC_NO_BONJOUR`).
        public var enabled: Bool
        /// Name actually registered (after conflict renaming); nil until registered.
        public var serviceName: String?

        public init(enabled: Bool, serviceName: String?) {
            self.enabled = enabled
            self.serviceName = serviceName
        }
    }

    public struct Bluetooth: Codable, Equatable, Sendable {
        /// "Allow Bluetooth Sync" in the menu.
        public var allowed: Bool
        /// `CMDS_SYNC_NO_BLUETOOTH` is set.
        public var disabledByEnvironment: Bool
        /// The app's Bluetooth permission (`CBManager.authorization`): "allowedAlways", "denied",
        /// "restricted" or "notDetermined".
        public var authorization: String
        /// Peripheral manager state: "off" (not created), "unknown", "resetting", "unsupported",
        /// "unauthorized", "poweredOff" or "poweredOn".
        public var managerState: String
        public var advertising: Bool
        /// L2CAP PSM published for the relay; nil when not published.
        public var psm: UInt16?
        /// Open Bluetooth relay channels.
        public var channels: Int
        /// Status as shown in the menu.
        public var status: String

        public init(allowed: Bool, disabledByEnvironment: Bool, authorization: String, managerState: String,
                    advertising: Bool, psm: UInt16?, channels: Int, status: String) {
            self.allowed = allowed
            self.disabledByEnvironment = disabledByEnvironment
            self.authorization = authorization
            self.managerState = managerState
            self.advertising = advertising
            self.psm = psm
            self.channels = channels
            self.status = status
        }
    }

    public struct Remote: Codable, Equatable, Sendable {
        public var enabled: Bool
        /// Relay host (ssh config alias); empty when not configured.
        public var host: String
        public var relayPort: UInt16
        /// The forward is believed to be up.
        public var forwarding: Bool
        public var status: String

        public init(enabled: Bool, host: String, relayPort: UInt16, forwarding: Bool, status: String) {
            self.enabled = enabled
            self.host = host
            self.relayPort = relayPort
            self.forwarding = forwarding
            self.status = status
        }
    }

    public struct Client: Codable, Equatable, Sendable {
        /// Device name sent in `hello` (empty before it); never the token.
        public var deviceName: String
        public var authenticated: Bool
        /// Remote IP, `bluetooth:<peer>` or `ssh:<relay host>`.
        public var peer: String
        /// "network", "bluetooth" or "ssh".
        public var path: String
        public var subscribedPanes: Int
        public var bytesSent: Int
        public var bytesReceived: Int
        /// ISO 8601.
        public var connectedSince: String
        public var connectedSeconds: Int

        public init(deviceName: String, authenticated: Bool, peer: String, path: String, subscribedPanes: Int,
                    bytesSent: Int, bytesReceived: Int, connectedSince: String, connectedSeconds: Int) {
            self.deviceName = deviceName
            self.authenticated = authenticated
            self.peer = peer
            self.path = path
            self.subscribedPanes = subscribedPanes
            self.bytesSent = bytesSent
            self.bytesReceived = bytesReceived
            self.connectedSince = connectedSince
            self.connectedSeconds = connectedSeconds
        }

        /// Path name for a peer label (see `SyncBluetooth.peerHostPrefix`, `SyncRemote.peerHostPrefix`).
        public static func path(forPeer peer: String) -> String {
            if peer.hasPrefix(SyncBluetooth.peerHostPrefix) { return "bluetooth" }
            if peer.hasPrefix(SyncRemote.peerHostPrefix) { return "ssh" }
            return "network"
        }
    }

    public init(enabled: Bool, state: String, port: UInt16?, fingerprint: String?, bonjour: Bonjour,
                pairingWindowOpen: Bool, pairedDevices: Int, bluetooth: Bluetooth, remote: Remote, clients: [Client]) {
        self.enabled = enabled
        self.state = state
        self.port = port
        self.fingerprint = fingerprint
        self.bonjour = bonjour
        self.pairingWindowOpen = pairingWindowOpen
        self.pairedDevices = pairedDevices
        self.bluetooth = bluetooth
        self.remote = remote
        self.clients = clients
    }
}
