import CmdsCore
import Foundation
import Observation

enum ConnectionStatus: Equatable {
    case idle
    case connecting
    case authenticating
    case connected
    case reconnecting(in: TimeInterval, reason: String?)
    /// Mac wants a pairing code (or the given one was wrong).
    case pairingRequired(message: String?)
    /// Gave up (protocol mismatch, rate limited...). User must act.
    case failed(message: String)

    var label: String {
        switch self {
        case .idle: return "Not connected"
        case .connecting: return "Connecting…"
        case .authenticating: return "Authenticating…"
        case .connected: return "Connected"
        case .reconnecting(let s, _): return "Reconnecting in \(Int(s.rounded(.up)))s"
        case .pairingRequired: return "Pairing required"
        case .failed: return "Disconnected"
        }
    }

    var isLive: Bool { self == .connected }
}

/// One connection to one Mac: authentication, reconnects, mirrored workspace state and pane screens.
/// Views observe it; all methods must be called on the main thread.
@MainActor
@Observable
final class CompanionClient {
    // MARK: Observable state
    private(set) var target: MacTarget?
    private(set) var status: ConnectionStatus = .idle
    private(set) var macName: String = ""
    private(set) var workspaces: [WorkspaceInfo] = []
    /// Bumped whenever any screen changes (cheap observation hook).
    private(set) var screens: [String: ScreenSnapshot] = [:]
    /// Panes that raised a `notification` and have not been viewed since.
    private(set) var unreadPaneIDs: Set<String> = []
    private(set) var unreadWorkspaceIDs: Set<String> = []
    private(set) var lastNotification: ServerMessage.Notification?
    private(set) var roundTripTime: TimeInterval?

    /// Whether the app is in the foreground (set by the scene).
    var isAppActive = true
    /// Pane the user is looking at (not posted as a local notification, cleared from unread).
    private(set) var viewedPaneID: String?

    // MARK: Private
    private let makeTransport: (MacTarget) -> SyncTransport
    private var transport: SyncTransport?
    private var mirror = ScreenMirror()
    private var backoff = SyncBackoff()
    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var pendingPairingCode: String?
    private var subscribedPaneIDs: [String] = []
    private var pingNonce = 0
    private var pingSentAt: [Int: Date] = [:]
    private var lastInbound = Date()

    init(makeTransport: @escaping (MacTarget) -> SyncTransport) {
        self.makeTransport = makeTransport
    }

    static func live() -> CompanionClient {
        CompanionClient { target in
            target.kind == .mock ? MockTransport() as SyncTransport : WebSocketTransport(target: target)
        }
    }

    // MARK: Connection lifecycle

    func connect(to target: MacTarget, pairingCode: String? = nil) {
        if self.target != target {
            workspaces = []
            screens = [:]
            mirror.removeAll()
            unreadPaneIDs = []
            unreadWorkspaceIDs = []
            macName = target.displayName
        }
        self.target = target
        pendingPairingCode = pairingCode
        backoff.reset()
        openTransport()
    }

    func submitPairingCode(_ code: String) {
        guard let target else { return }
        connect(to: target, pairingCode: code)
    }

    /// Stop and forget the current Mac (back to the Mac picker).
    func disconnect() {
        teardown()
        target = nil
        status = .idle
        workspaces = []
        screens = [:]
        mirror.removeAll()
    }

    /// Forget the stored token for the current Mac and ask for a new code.
    func unpair() {
        guard let target else { return }
        TokenStore.deleteToken(for: target.id)
        teardown()
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
            if Date().timeIntervalSince(lastInbound) > 20 { openTransport() }
        default:
            break
        }
    }

    private func openTransport() {
        guard let target else { return }
        teardown()
        status = .connecting
        let transport = makeTransport(target)
        self.transport = transport
        transport.onEvent = { [weak self, weak transport] event in
            guard let self, let transport, transport === self.transport else { return }
            self.handle(event)
        }
        transport.start()
    }

    private func teardown() {
        reconnectTask?.cancel()
        reconnectTask = nil
        pingTask?.cancel()
        pingTask = nil
        transport?.onEvent = nil
        transport?.close()
        transport = nil
    }

    private func handle(_ event: TransportEvent) {
        lastInbound = Date()
        switch event {
        case .connected:
            status = .authenticating
            guard let target else { return }
            let token = target.kind == .mock ? nil : TokenStore.token(for: target.id)
            let code = pendingPairingCode
            send(.hello(.init(deviceName: DeviceIdentity.name, deviceID: DeviceIdentity.id,
                              pairingCode: code, token: code == nil ? token : nil)))
        case .message(let message):
            handle(message)
        case .disconnected(let reason):
            transport = nil
            pingTask?.cancel()
            switch status {
            case .pairingRequired, .failed, .idle:
                return // auth failure already reported; don't loop
            default:
                scheduleReconnect(reason: reason)
            }
        }
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
            pendingPairingCode = nil
            if let target, target.kind != .mock {
                TokenStore.setToken(welcome.token, for: target.id)
                var named = target
                named.displayName = welcome.macName
                RecentMacs.remember(named)
            }
            status = .connected
            backoff.reset()
            mirror.removeAll()
            if !subscribedPaneIDs.isEmpty { send(.subscribe(.init(paneIDs: subscribedPaneIDs))) }
            startPinging()
            if !ProcessInfo.processInfo.arguments.contains("-noNotify") {
                AttentionNotifier.shared.requestAuthorizationIfNeeded()
            }

        case .error(let info):
            if info.code == .invalidToken, let target { TokenStore.deleteToken(for: target.id) }
            switch info.code {
            case .pairingRequired, .invalidToken:
                status = .pairingRequired(message: nil)
                pendingPairingCode = nil
            case .invalidPairingCode:
                status = .pairingRequired(message: info.message)
                pendingPairingCode = nil
            case .unsupportedVersion, .rateLimited:
                status = .failed(message: info.message)
            default:
                break // per-request error; connection stays up
            }
            if info.code.isAuthFailure { teardown() }

        case .state(let state):
            workspaces = state.workspaces
            let live = Set(state.workspaces.flatMap { $0.panes.map(\.id) })
            unreadPaneIDs.formIntersection(live)
            unreadWorkspaceIDs.formIntersection(Set(state.workspaces.map(\.id)))
            for gone in screens.keys where !live.contains(gone) {
                screens[gone] = nil
                mirror.remove(paneID: gone)
            }

        case .screen(let screen):
            apply(mirror.apply(screen))

        case .screenDiff(let diff):
            apply(mirror.apply(diff))

        case .notification(let note):
            lastNotification = note
            if let paneID = note.paneID, paneID == viewedPaneID, isAppActive {
                return // user is looking at it
            }
            if let paneID = note.paneID { unreadPaneIDs.insert(paneID) }
            unreadWorkspaceIDs.insert(note.workspaceID)
            AttentionNotifier.shared.post(title: note.title, body: note.body, macName: macName,
                                          workspaceID: note.workspaceID, paneID: note.paneID)

        case .pong(let pong):
            if let nonce = pong.nonce, let sent = pingSentAt.removeValue(forKey: nonce) {
                roundTripTime = Date().timeIntervalSince(sent)
            }
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
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                if Date().timeIntervalSince(self.lastInbound) > 30 {
                    self.scheduleReconnect(reason: "Mac stopped responding")
                    self.transport?.onEvent = nil
                    self.transport?.close()
                    self.transport = nil
                    return
                }
                self.pingNonce += 1
                self.pingSentAt = [self.pingNonce: Date()]
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
        send(.input(.init(paneID: paneID, text: text)))
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
