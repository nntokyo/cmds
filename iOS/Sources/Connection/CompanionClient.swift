import CmdsCore
import Foundation
import Observation

/// One connection to one Mac: authentication, reconnects, mirrored workspace state and pane screens.
/// Views observe it; all methods must be called on the main thread.
///
/// Trust (docs/internals/sync-protocol.md): every connection is TLS pinned to the Mac certificate fingerprint saved at
/// pairing (`PairingStore`). Pairing pins the fingerprint first, from the Mac's QR code or after the user
/// compared it with the Mac's pairing window, and only then sends the code. The token is only ever sent
/// on a connection verified against the pin saved with it.
@MainActor
@Observable
final class CompanionClient {
    // MARK: Observable state
    private(set) var target: MacTarget?
    private(set) var status: ConnectionStatus = .idle
    private(set) var macName: String = ""
    private(set) var workspaces: [WorkspaceInfo] = []
    /// Mac-wide CPU/memory from the latest `state` (nil for Macs that do not send it).
    private(set) var systemStats: SystemStats?
    /// Account limits of the coding agents (Claude, Codex) from the latest `state` (empty for older Macs).
    private(set) var agentLimits: [AgentLimits] = []
    /// Bumped whenever any screen changes (cheap observation hook).
    private(set) var screens: [String: ScreenSnapshot] = [:]
    /// Files of preview panes fetched with `requestFile` (images/PDFs shown on the phone).
    let previewFiles = PreviewFileStore()
    /// Optional protocol additions this build understands (`hello.features`).
    static let features = [SyncFeature.previewPanes]
    /// Panes that raised a `notification` and have not been viewed since.
    private(set) var unreadPaneIDs: Set<String> = []
    private(set) var unreadWorkspaceIDs: Set<String> = []
    /// How the live connection reaches the Mac (Wi‑Fi or the Bluetooth fallback); nil when not connected.
    private(set) var linkPath: SyncLinkPath?
    /// Fingerprint pinned for the pairing in progress (from the QR code, or confirmed by the user).
    /// Saved with the token once the Mac accepts the code.
    private(set) var pairingPin: SyncFingerprint?

    /// Whether the app is in the foreground (set by the scene).
    var isAppActive = true
    /// Pane the user is looking at (not posted as a local notification, cleared from unread).
    private(set) var viewedPaneID: String?

    // MARK: Private
    /// Path and progress of the connection attempts (status badge accessibility value, debug row).
    let diagnostics = ConnectionDiagnostics.shared
    private let makeTransport: (MacTarget, SyncTLS.PeerPolicy?) -> SyncTransport
    private var transport: SyncTransport?
    /// Policy of `transport` (nil for the demo Mac).
    private var transportPolicy: SyncTLS.PeerPolicy?
    private var mirror = ScreenMirror()
    private var backoff = SyncBackoff()
    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    /// A connection that is neither up nor failed after this long is abandoned and retried
    /// (NWConnection can sit in "preparing" indefinitely, e.g. while the Mac's firewall drops packets).
    /// Leaves room for the Bluetooth fallback (scan, connect, L2CAP, TLS) after the network attempt.
    private static let connectTimeout: Duration = .seconds(20)
    /// Interval of the keep-alive `ping` while connected.
    private static let pingInterval: Duration = .seconds(10)
    /// A connection with nothing received for this long is dropped and reconnected.
    private static let inboundTimeout: TimeInterval = 30
    /// Back in the foreground, a connection with nothing received for this long is reopened at once.
    private static let resumeStaleAfter: TimeInterval = 20
    /// The Mac takes at most this much UTF-8 text per `input` message.
    private static let maxInputBytes = 16 * 1024
    private var pendingPairingCode: String?
    private var subscribedPaneIDs: [String] = []
    private var pingNonce = 0
    private var lastInbound = Date()
    /// Shown once when protocol v1 pairings were dropped at launch.
    private var upgradeNotice: String?

    init(makeTransport: @escaping (MacTarget, SyncTLS.PeerPolicy?) -> SyncTransport) {
        self.makeTransport = makeTransport
        if PairingStore.removeLegacyTokens() {
            upgradeNotice = String(localized: "cmds now encrypts the connection to your Mac and checks its identity. Pair again once: open Pair iPhone/iPad… in cmds on the Mac and scan the code.")
        }
    }

    static func live() -> CompanionClient {
        _ = NetworkPathMonitor.shared // learn about Wi‑Fi before the first connection needs it
        return CompanionClient { target, policy in
            guard target.kind != .mock, let policy else { return MockTransport() }
            // Network first, Bluetooth when the Mac cannot be reached over IP (same pinned TLS either way).
            // Debug builds may force one path (`-cmdsTransport`, docs/internals/testing.md "Testing sync on a device").
            return FallbackTransport(target: target, policy: policy, mode: TransportMode.current)
        }
    }

    /// A pairing attempt (code pending) is in flight.
    var isPairing: Bool { pendingPairingCode != nil }

    // MARK: Connection lifecycle

    /// Connects with the saved pairing (pinned certificate + token); without one, asks for pairing.
    func connect(to target: MacTarget) {
        select(target)
        backoff.reset()
        guard target.kind == .mock || PairingStore.isPaired(target.id) else {
            teardown()
            status = .pairingRequired(message: upgradeNotice)
            upgradeNotice = nil
            return
        }
        openTransport()
    }

    /// Pairs with a scanned QR code: pins its fingerprint, then sends its code over a connection whose
    /// certificate matched.
    func pair(with payload: SyncPairingPayload, target: MacTarget) {
        select(target)
        pairingPin = payload.fingerprint
        pendingPairingCode = payload.code
        backoff.reset()
        openTransport()
    }

    /// Manual pairing, step 1: read the certificate the Mac presents. The handshake is refused, so nothing
    /// (not even `hello`) is sent; the result is `.confirmIdentity`.
    func checkIdentity() {
        guard let target, target.kind != .mock else { return }
        forgetPairingInProgress()
        openTransport(policy: .probe)
    }

    /// Manual pairing, step 2: the user saw the same identity in the Mac's pairing window.
    func confirmIdentity(_ fingerprint: SyncFingerprint) {
        guard case .confirmIdentity(let shown) = status, shown == fingerprint else { return }
        pairingPin = fingerprint
        status = .enterCode(message: nil)
    }

    /// Manual pairing: the identities differ. Pair with nothing that answered.
    func rejectIdentity() {
        pairingPin = nil
        status = .pairingRequired(message: String(localized: "The identities did not match, so nothing was sent. Something else may be answering for this Mac. Scan the QR code in the Mac's pairing window instead."))
    }

    /// Manual pairing, step 3 (also after a wrong code): sends the code over a connection pinned to the
    /// identity confirmed for this pairing.
    func submitPairingCode(_ code: String) {
        guard target != nil, pairingPin != nil else { return }
        pendingPairingCode = code
        backoff.reset()
        openTransport()
    }

    /// Stop and forget the current Mac (back to the Mac picker).
    func disconnect() {
        teardown()
        target = nil
        status = .idle
        forgetPairingInProgress()
        clearMirroredState()
    }

    /// Forget the saved pairing (pin and token) for the current Mac and start pairing again.
    func unpair() {
        guard let target else { return }
        PairingStore.delete(for: target.id)
        teardown()
        forgetPairingInProgress()
        status = .pairingRequired(message: nil)
    }

    /// Call when the app returns to the foreground: reconnect right away instead of waiting for backoff.
    func resumeIfNeeded() {
        guard target != nil else { return }
        switch status {
        case .reconnecting, .idle:
            backoff.reset()
            openTransport()
        case .connected:
            if Date().timeIntervalSince(lastInbound) > Self.resumeStaleAfter { openTransport() }
        default:
            break
        }
    }

    private func select(_ target: MacTarget) {
        if self.target != target {
            clearMirroredState()
            unreadPaneIDs = []
            unreadWorkspaceIDs = []
            macName = target.displayName
        }
        self.target = target
        forgetPairingInProgress()
    }

    /// Drops the pin and code of a pairing in progress (the saved pairing is untouched).
    private func forgetPairingInProgress() {
        pairingPin = nil
        pendingPairingCode = nil
    }

    /// Drops everything mirrored from the Mac (workspaces, stats, screens).
    private func clearMirroredState() {
        workspaces = []
        systemStats = nil
        agentLimits = []
        screens = [:]
        mirror.removeAll()
    }

    /// Opens a connection. Pinned to the pairing in progress, else to the saved pairing; `.probe` only for
    /// manual pairing. Without any pin there is nothing to connect to safely.
    private func openTransport(policy requested: SyncTLS.PeerPolicy? = nil) {
        guard let target else { return }
        teardown()
        var policy = requested
        if target.kind != .mock, policy == nil {
            guard let pin = pairingPin ?? PairingStore.pairing(for: target.id)?.fingerprint else {
                status = .pairingRequired(message: nil)
                return
            }
            policy = .pinned(pin)
        }
        status = policy == .probe ? .checkingIdentity : .connecting
        diagnostics.begin(mode: target.kind == .mock ? .auto : TransportMode.current)
        transportPolicy = policy
        let transport = makeTransport(target, policy)
        self.transport = transport
        transport.onEvent = { [weak self, weak transport] event in
            guard let self, let transport, transport === self.transport else { return }
            self.handle(event)
        }
        transport.start()
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.connectTimeout)
            guard !Task.isCancelled, let self, transport === self.transport else { return }
            let hint = String(localized: "The Mac did not answer. Check that cmds is running and allowed in the Mac's firewall.")
            if !self.status.isLive { self.diagnostics.failed(nil, "timed out after \(Self.connectTimeout)") }
            switch self.status {
            case .connecting, .authenticating:
                self.dropTransport()
                self.scheduleReconnect(reason: hint)
            case .checkingIdentity:
                self.dropTransport()
                self.status = .pairingRequired(message: hint)
            default:
                break
            }
        }
    }

    private func dropTransport() {
        linkPath = nil
        diagnostics.ended()
        transport?.onEvent = nil
        transport?.close()
        transport = nil
    }

    private func teardown() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        pingTask?.cancel()
        pingTask = nil
        dropTransport()
    }

    private func handle(_ event: TransportEvent) {
        lastInbound = Date()
        switch event {
        case .connected:
            linkPath = transport?.linkPath
            if let linkPath { diagnostics.stage(linkPath, "TLS ok, hello sent") }
            status = .authenticating
            sendHello()
        case .message(let message):
            handle(message)
        case .identityPresented(let fingerprint):
            teardown()
            status = .confirmIdentity(fingerprint)
        case .identityMismatch:
            teardown()
            let duringPairing = pairingPin != nil
            forgetPairingInProgress()
            status = .identityMismatch(message: duringPairing
                ? String(localized: "The Mac that answered does not have the identity from the pairing code, so the code was not sent. Make sure you scanned this Mac's code and are on the same network.")
                : String(localized: "“\(macName)” presented a different identity than when you paired, so nothing was sent. If you reset its sync identity, pair again. Otherwise something else may be answering for it."))
        case .disconnected(let reason):
            transport = nil
            linkPath = nil
            diagnostics.ended()
            pingTask?.cancel()
            switch status {
            case .checkingIdentity:
                status = .pairingRequired(message: reason.map { String(localized: "Could not read the Mac's identity: \($0)") })
            case .pairingRequired, .confirmIdentity, .enterCode, .identityMismatch, .failed, .idle:
                return // already reported; don't loop
            default:
                scheduleReconnect(reason: reason)
            }
        }
    }

    /// First message on a connection verified against `transportPolicy`'s pin: the pairing code, or the
    /// token saved with exactly that pin.
    private func sendHello() {
        guard let target else { return }
        if target.kind == .mock {
            send(Self.hello())
            return
        }
        guard case .pinned(let pin) = transportPolicy else { return dropTransport() }
        if let code = pendingPairingCode, let pairingPin, pairingPin.matches(pin) {
            send(Self.hello(pairingCode: code))
        } else if pendingPairingCode == nil, let saved = PairingStore.pairing(for: target.id), saved.fingerprint.matches(pin) {
            send(Self.hello(token: saved.token))
        } else {
            // The pin changed under this connection; send nothing and start over.
            teardown()
            status = .pairingRequired(message: nil)
        }
    }

    /// `hello` for this device with at most one credential: the pairing code or the saved token.
    private static func hello(pairingCode: String? = nil, token: String? = nil) -> ClientMessage {
        .hello(.init(deviceName: DeviceIdentity.name, deviceID: DeviceIdentity.id, features: features,
                     pairingCode: pairingCode, token: token))
    }

    private func scheduleReconnect(reason: String?) {
        let delay = backoff.nextDelay()
        status = .reconnecting(in: delay, reason: reason)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.openTransport()
        }
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case .welcome(let welcome):
            macName = welcome.macName
            if let target, target.kind != .mock, case .pinned(let pin) = transportPolicy {
                PairingStore.save(MacPairing(fingerprint: pin, token: welcome.token), for: target.id)
                var named = target
                named.displayName = welcome.macName
                RecentMacs.remember(named)
            }
            forgetPairingInProgress()
            status = .connected
            diagnostics.connected(linkPath)
            backoff.reset()
            mirror.removeAll()
            if !subscribedPaneIDs.isEmpty { send(.subscribe(.init(paneIDs: subscribedPaneIDs))) }
            startPinging()
            if !ProcessInfo.processInfo.arguments.contains("-noNotify") {
                AttentionNotifier.shared.requestAuthorizationIfNeeded()
            }

        case .error(let info):
            switch info.code {
            case .pairingRequired, .invalidToken:
                // The token is gone on the Mac (revoked, replaced): drop it together with its pin.
                if let target, !isPairing { PairingStore.delete(for: target.id) }
                forgetPairingInProgress()
                status = .pairingRequired(message: info.code == .invalidToken ? info.localizedMessage : nil)
            case .invalidPairingCode:
                // The identity stays pinned for this pairing; only the code has to be entered again.
                pendingPairingCode = nil
                status = pairingPin != nil ? .enterCode(message: info.localizedMessage) : .pairingRequired(message: info.localizedMessage)
            case .unsupportedVersion, .rateLimited:
                pendingPairingCode = nil
                status = .failed(message: info.localizedMessage)
            default:
                previewFiles.requestFailed(info.message) // per-request error; connection stays up
            }
            if info.code.isAuthFailure {
                diagnostics.failed(linkPath, "Mac refused: \(info.code.rawValue)")
                teardown()
            }

        case .state(let state):
            // Usage samples arrive every ~2 s; skip no-op assignments so unchanged parts do not re-render.
            if workspaces != state.workspaces { workspaces = state.workspaces }
            if systemStats != state.system { systemStats = state.system }
            if agentLimits != state.agentLimits ?? [] { agentLimits = state.agentLimits ?? [] }
            let live = Set(state.workspaces.flatMap { $0.panes.map(\.id) })
            unreadPaneIDs.formIntersection(live)
            unreadWorkspaceIDs.formIntersection(Set(state.workspaces.map(\.id)))
            previewFiles.retain(paneIDs: live)
            for gone in screens.keys where !live.contains(gone) {
                screens[gone] = nil
                mirror.remove(paneID: gone)
            }

        case .screen(let screen):
            apply(mirror.apply(screen))

        case .screenDiff(let diff):
            apply(mirror.apply(diff))

        case .notification(let note):
            if let paneID = note.paneID, paneID == viewedPaneID, isAppActive {
                return // user is looking at it
            }
            if let paneID = note.paneID { unreadPaneIDs.insert(paneID) }
            unreadWorkspaceIDs.insert(note.workspaceID)
            AttentionNotifier.shared.post(title: note.title, body: note.body, macName: macName,
                                          workspaceID: note.workspaceID, paneID: note.paneID)

        case .file(let piece):
            previewFiles.receive(piece)

        case .pong:
            break // `lastInbound` was updated on arrival; that is all a pong is for
        }
    }

    private func apply(_ result: ScreenMirror.ApplyResult) {
        switch result {
        case .updated(let paneID):
            screens[paneID] = mirror[paneID]
        case .needsFullScreen(let paneID):
            send(.requestScreen(.init(paneID: paneID)))
        case .stale:
            break
        }
    }

    private func startPinging() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pingInterval)
                guard let self, !Task.isCancelled else { return }
                if Date().timeIntervalSince(self.lastInbound) > Self.inboundTimeout {
                    self.scheduleReconnect(reason: String(localized: "The Mac stopped responding."))
                    self.transport?.onEvent = nil
                    self.transport?.close()
                    self.transport = nil
                    return
                }
                self.pingNonce += 1
                self.send(.ping(.init(nonce: self.pingNonce)))
            }
        }
    }

    // MARK: Commands

    private func send(_ message: ClientMessage) {
        transport?.send(message)
    }

    /// Panes whose screens should stream (visible panes).
    func setVisiblePanes(_ paneIDs: [String]) {
        guard paneIDs != subscribedPaneIDs else { return }
        subscribedPaneIDs = paneIDs
        if status.isLive { send(.subscribe(.init(paneIDs: paneIDs))) }
    }

    func setViewedPane(_ paneID: String?, workspaceID: String?) {
        viewedPaneID = paneID
        if let paneID { unreadPaneIDs.remove(paneID) }
        if let workspaceID, let ws = workspaces.first(where: { $0.id == workspaceID }),
           !ws.panes.contains(where: { unreadPaneIDs.contains($0.id) }) {
            unreadWorkspaceIDs.remove(workspaceID)
        }
    }

    func sendText(_ text: String, to paneID: String) {
        guard !text.isEmpty else { return }
        var chunk = ""
        var chunkBytes = 0
        for character in text {
            let size = character.utf8.count
            if chunkBytes + size > Self.maxInputBytes {
                send(.input(.init(paneID: paneID, text: chunk)))
                chunk = ""
                chunkBytes = 0
            }
            chunk.append(character)
            chunkBytes += size
        }
        if !chunk.isEmpty { send(.input(.init(paneID: paneID, text: chunk))) }
    }

    /// Asks the Mac for the file shown in a preview pane (the Mac sends only that pane's own file).
    func requestFile(paneID: String) {
        guard status.isLive else { return }
        previewFiles.begin(paneID: paneID)
        send(.requestFile(.init(paneID: paneID)))
    }

    func sendKey(_ key: SyncKey, to paneID: String) {
        send(.key(.init(paneID: paneID, key: key)))
    }

    func selectWorkspaceOnMac(_ id: String) {
        send(.selectWorkspace(.init(id: id)))
    }

    func focusPaneOnMac(_ id: String) {
        send(.focusPane(.init(id: id)))
    }

    // MARK: Derived

    func workspace(_ id: String?) -> WorkspaceInfo? {
        guard let id else { return nil }
        return workspaces.first { $0.id == id }
    }

    func needsAttention(_ workspace: WorkspaceInfo) -> Bool {
        workspace.attention || unreadWorkspaceIDs.contains(workspace.id) || workspace.panes.contains { needsAttention($0) }
    }

    func needsAttention(_ pane: PaneInfo) -> Bool {
        pane.attention || unreadPaneIDs.contains(pane.id)
    }
}
