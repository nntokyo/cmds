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
    /// Rows above each streamed pane's screen (`scrollback`); none for Macs without `SyncFeature.scrollback`. Asked
    /// for with `refreshHistory(paneID:)`. A Mac with `SyncFeature.scrollbackStream` adds the rows that scroll off the
    /// screen to every screen update, appended here in the same update; while the pane is read
    /// (`setReadingHistory(paneID:reading:)`) nothing else changes them (see `pendingHistories`).
    private(set) var histories: [String: PaneHistory] = [:]
    /// Files of preview panes fetched with `requestFile` (images/PDFs shown on the phone).
    let previewFiles = PreviewFileStore()
    /// Optional protocol additions this build understands (`hello.features`).
    static let features = [SyncFeature.previewPanes, SyncFeature.scrollbackStream]
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
    /// Requests the connected Mac answers (`welcome.features`).
    private var macFeatures: Set<String> = []
    private var historyRequestedAt: [String: Date] = [:]
    /// A request that waits for the end of `historyInterval` (one per pane); with a streaming Mac also the next try of
    /// an unanswered request.
    private var historyTasks: [String: Task<Void, Never>] = [:]
    /// Rows asked for per `requestScrollback`, and at most one request per pane this often. Bluetooth carries less
    /// (1000 rows of a wide pane can be about a megabyte).
    private static let historyLines = 500
    private static let historyLinesBluetooth = 200
    private static let historyInterval: TimeInterval = 3
    private static let historyIntervalBluetooth: TimeInterval = 10
    /// Streaming Mac: panes whose `requestScrollback` it answered on this connection, so their screen updates carry
    /// the rows that scroll off (`scrolledOff`) or `historyReset`.
    private var streamedHistoryPaneIDs: Set<String> = []
    /// Panes whose earlier output the user is reading (`setReadingHistory`).
    private var readingPaneIDs: Set<String> = []
    /// Streaming Mac, pane being read: its rows once they no longer continue the shown ones (a reset or a new
    /// connection whose answer does not continue them, `readingHistoryCap` reached). The shown rows stay as they are,
    /// because any change above the rows being read would move them; these replace them when reading ends.
    private var pendingHistories: [String: PaneHistory] = [:]
    /// Rows kept above a screen, and while it is read: dropping rows at the top would move the text being read.
    private static let historyCap = 2000
    private static let readingHistoryCap = 10_000

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
            macFeatures = Set(welcome.features ?? [])
            cancelHistoryRequests()
            streamedHistoryPaneIDs = []
            // Possibly another Mac (pane ids are per Mac) or one without `scrollback`: the views ask again. With a
            // streaming Mac, rows being read stay until reading ends.
            if streamsHistory {
                for paneID in Set(histories.keys).union(pendingHistories.keys) { replaceHistory(paneID, with: nil) }
            } else {
                histories = [:]
                pendingHistories = [:]
            }
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
            forgetHistories { !live.contains($0) }

        case .screen(let screen):
            // The rows that left the screen's top go in with it, so both are drawn in the same frame.
            let result = mirror.apply(screen)
            apply(result)
            if result != .stale {
                extendHistory(screen.paneID, scrolledOff: screen.scrolledOff, reset: screen.historyReset == true)
            }

        case .screenDiff(let diff):
            let result = mirror.apply(diff)
            apply(result)
            // Also when the diff did not apply (a full screen is requested): the rows are relative to the previous
            // update the Mac sent, not to the copy here.
            if result != .stale {
                extendHistory(diff.paneID, scrolledOff: diff.scrolledOff, reset: diff.historyReset == true)
            }

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

        case .scrollback(let rows):
            // Follows the full `screen` it was read with; panes no longer streamed are dropped.
            guard subscribedPaneIDs.contains(rows.paneID) else { break }
            if streamsHistory {
                // From here on the Mac sends the rows that scroll off with the screen: no further requests.
                streamedHistoryPaneIDs.insert(rows.paneID)
                historyTasks.removeValue(forKey: rows.paneID)?.cancel()
                if continueHistory(rows.paneID, with: rows.lines) { break }
            }
            replaceHistory(rows.paneID, with: rows.lines)

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
        forgetHistories { !paneIDs.contains($0) }
        for paneID in Array(historyTasks.keys) + Array(historyRequestedAt.keys) where !paneIDs.contains(paneID) {
            historyTasks.removeValue(forKey: paneID)?.cancel()
            historyRequestedAt[paneID] = nil
        }
        if status.isLive { send(.subscribe(.init(paneIDs: paneIDs))) }
    }

    // MARK: Earlier output

    /// The connected (or last) Mac sends the rows that scroll off a pane's screen with its screen updates
    /// (`SyncFeature.scrollbackStream`), so `histories` stay continuous without asking again.
    var streamsHistory: Bool { macFeatures.contains(SyncFeature.scrollbackStream) }

    /// Asks the Mac for the rows above a streamed pane's screen (Macs with `SyncFeature.scrollback`). Calls within
    /// `historyInterval` of the last request are folded into one request at its end. A streaming Mac is asked once
    /// per pane and connection (again after `historyReset`), until it answers.
    func refreshHistory(paneID: String) {
        guard canRequestHistory(paneID: paneID), historyTasks[paneID] == nil else { return }
        if streamsHistory, streamedHistoryPaneIDs.contains(paneID) { return }
        let interval = linkPath == .bluetooth ? Self.historyIntervalBluetooth : Self.historyInterval
        let wait = historyRequestedAt[paneID].map { interval - Date().timeIntervalSince($0) } ?? 0
        guard wait <= 0 else {
            historyTasks[paneID] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled else { return }
                self.historyTasks[paneID] = nil
                self.refreshHistory(paneID: paneID)
            }
            return
        }
        historyRequestedAt[paneID] = Date()
        let lines = linkPath == .bluetooth ? Self.historyLinesBluetooth : Self.historyLines
        send(.requestScrollback(.init(paneID: paneID, lines: lines)))
        guard streamsHistory else { return }
        // The Mac may leave a request unanswered while output keeps moving the rows (sync-protocol.md "Scrollback"),
        // and with the rows streamed nothing else asks again: try again until it answers.
        historyTasks[paneID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard let self, !Task.isCancelled else { return }
            self.historyTasks[paneID] = nil
            self.refreshHistory(paneID: paneID)
        }
    }

    /// The pane is streamed from a connected Mac that answers `requestScrollback`.
    func canRequestHistory(paneID: String) -> Bool {
        status.isLive && macFeatures.contains(SyncFeature.scrollback) && subscribedPaneIDs.contains(paneID)
    }

    /// The view of a pane stopped following its screen to read earlier output (`reading`), or follows it again.
    /// While a pane is read with a streaming Mac, the rows that scroll off its screen are still added below the shown
    /// ones, and nothing else changes them: no rows are dropped below `readingHistoryCap`, and rows that do not
    /// continue them wait in `pendingHistories`. When reading ends, those are shown and the rows are trimmed to
    /// `historyCap`; the view calls this once it keeps the bottom in place again.
    func setReadingHistory(paneID: String, reading: Bool) {
        if reading {
            readingPaneIDs.insert(paneID)
        } else if readingPaneIDs.remove(paneID) != nil {
            showPendingHistory(paneID)
        }
    }

    /// Latest: shows the rows held back while reading before the view scrolls to the screen. The pane still counts as
    /// read until its view follows the screen again (`setReadingHistory`).
    func showLatestHistory(paneID: String) {
        showPendingHistory(paneID)
    }

    /// The pending rows (else the shown ones), trimmed to `historyCap`.
    private func showPendingHistory(_ paneID: String) {
        guard var history = pendingHistories.removeValue(forKey: paneID) ?? histories[paneID] else { return }
        history.dropOldest(history.lines.count - Self.historyCap)
        if histories[paneID] != history { histories[paneID] = history }
    }

    /// A pane's rows from a `scrollback` answer, or none (new connection). While a streaming Mac's pane is read, they
    /// wait in `pendingHistories` and the shown rows stay.
    private func replaceHistory(_ paneID: String, with lines: [String]?) {
        let history = lines.map { PaneHistory(lines: $0) }
        if streamsHistory, readingPaneIDs.contains(paneID) {
            pendingHistories[paneID] = history ?? PaneHistory()
            return
        }
        pendingHistories[paneID] = nil
        if histories[paneID] != history { histories[paneID] = history }
    }

    /// `scrolledOff` / `historyReset` of a screen update from a streaming Mac (for panes whose request it answered).
    private func extendHistory(_ paneID: String, scrolledOff rows: [String]?, reset: Bool) {
        guard streamsHistory, streamedHistoryPaneIDs.contains(paneID) else { return }
        if reset {
            // The rows above the screen no longer continue these: ask again. The answer replaces them, or adds the
            // newer rows when it still has the last of them (`continueHistory`). Until then they stay: dropping them
            // at once would make the screen jump whenever rows above it are in view (a full scrollback resets often).
            streamedHistoryPaneIDs.remove(paneID)
            refreshHistory(paneID: paneID)
            return
        }
        if let rows { appendHistory(paneID, rows) }
    }

    /// A streaming Mac's answer that still has the last shown rows (after a reset that only dropped the oldest rows of
    /// a full scrollback, or a new connection): adds the newer rows below them, so rows being read stay where they are
    /// and keep growing. False when it does not continue them, or reaches further back while the pane is not read.
    private func continueHistory(_ paneID: String, with answer: [String]) -> Bool {
        guard let shown = histories[paneID]?.lines, let newer = Self.rows(after: shown, in: answer) else { return false }
        if !readingPaneIDs.contains(paneID), answer.count > shown.count + newer.count { return false }
        pendingHistories[paneID] = nil
        appendHistory(paneID, Array(newer))
        return true
    }

    /// Adds rows below a pane's rows, or below the pending ones while there are. Rows being read are never dropped at
    /// the top: once they are full they stay, and the rest waits in `pendingHistories`.
    private func appendHistory(_ paneID: String, _ rows: [String]) {
        guard !rows.isEmpty else { return }
        let reading = readingPaneIDs.contains(paneID)
        let cap = reading ? Self.readingHistoryCap : Self.historyCap
        if pendingHistories[paneID] != nil {
            pendingHistories[paneID]?.append(rows, keepingAtMost: cap)
        } else if reading, (histories[paneID]?.lines.count ?? 0) + rows.count > cap {
            var pending = histories[paneID] ?? PaneHistory()
            pending.append(rows, keepingAtMost: cap)
            pendingHistories[paneID] = pending
        } else {
            histories[paneID, default: PaneHistory()].append(rows, keepingAtMost: cap)
        }
    }

    /// The rows of `answer` after the last of `shown`, when `answer` has those last rows (the latest place, so repeated
    /// text adds as few rows as possible). Needs enough of them, some not blank, so the match is not a coincidence.
    static func rows(after shown: [String], in answer: [String]) -> ArraySlice<String>? {
        let tail = shown.suffix(24)
        guard tail.count >= 8, tail.filter({ !$0.isEmpty }).count >= 3 else { return nil }
        var end = answer.count
        while end >= tail.count {
            if answer[(end - tail.count)..<end].elementsEqual(tail) { return answer[end...] }
            end -= 1
        }
        return nil
    }

    /// Drops the rows (and the reading state) of panes that are no longer streamed or gone.
    private func forgetHistories(where gone: (String) -> Bool) {
        for paneID in histories.keys where gone(paneID) { histories[paneID] = nil }
        pendingHistories = pendingHistories.filter { !gone($0.key) }
        streamedHistoryPaneIDs = streamedHistoryPaneIDs.filter { !gone($0) }
        readingPaneIDs = readingPaneIDs.filter { !gone($0) }
    }

    private func cancelHistoryRequests() {
        historyTasks.values.forEach { $0.cancel() }
        historyTasks = [:]
        historyRequestedAt = [:]
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
