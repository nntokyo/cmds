import AppKit
import CmdsCore
import Combine
import Network
import os

/// Sync server log (subsystem tokyo.n-n.cmds, category sync). Never log tokens.
let syncLog = Logger(subsystem: "tokyo.n-n.cmds", category: "sync")

extension Notification.Name {
    /// Posted on main when the pairing code, listener status, paired or connected devices change.
    static let syncServerDidChange = Notification.Name("syncServerDidChange")
}

/// Serves the iOS companion (docs/SYNC.md): WebSocket listener + Bonjour, pairing, workspace
/// state, screen streaming and input. Network I/O runs on `queue`; everything else on main.
@MainActor
final class SyncServer {
    static let shared = SyncServer()

    static let enabledDefaultsKey = "SyncEnabled"
    /// Incoming frames larger than this are rejected (the phone only sends small messages).
    static let maxFrameBytes = 1024 * 1024
    static let helloTimeout: TimeInterval = 10
    static let codeLifetime: TimeInterval = 10 * 60
    /// Wrong codes allowed per code before a new one is drawn.
    static let maxFailuresPerCode = 5
    static let maxConnections = 16
    static let maxPendingPerHost = 4
    static let maxSubscribedPanes = 32
    /// Text in one `input` message (the phone sends keystrokes, lines or a paste).
    static let maxInputBytes = 16 * 1024
    /// Input a client may send per second; more is dropped with `rateLimited`.
    static let maxInputBytesPerSecond = 64 * 1024
    static let screenInterval: TimeInterval = 0.1
    static let stateInterval: TimeInterval = 0.1
    /// Minimum spacing of `state` pushes caused only by resource-usage samples.
    static let usageStateInterval: TimeInterval = 2

    final class Client {
        let connection: SyncConnection
        let connectedAt = Date()
        var authenticated = false
        var deviceName = ""
        var tokenHash: String?
        var streamer = ScreenStreamer()
        var subscribed: Set<String> = []
        var helloTimer: DispatchWorkItem?
        /// Set once a closing error was sent; later frames (e.g. pipelined hellos) are ignored.
        var closing = false
        var inputWindowStart = Date.distantPast
        var inputBytesInWindow = 0

        /// Charges `bytes` of input to the current one-second window; false when over budget.
        func spendInput(_ bytes: Int, now: Date = Date()) -> Bool {
            if now.timeIntervalSince(inputWindowStart) >= 1 {
                inputWindowStart = now
                inputBytesInWindow = 0
            }
            inputBytesInWindow += bytes
            return inputBytesInWindow <= SyncServer.maxInputBytesPerSecond
        }

        init(connection: SyncConnection) { self.connection = connection }
    }

    struct ConnectedDevice {
        var name: String
        var host: String
        var since: Date
        /// Matches `SyncDeviceStore.Device.tokenHash`.
        var tokenHash: String
    }

    let macName: String
    let store = SyncDeviceStore()
    private(set) var pairingCode: String = PairingToken.generateCode()
    private(set) var codeExpiresAt = Date()
    private(set) var port: UInt16?
    private(set) var statusText = "Stopped"

    private let queue = DispatchQueue(label: "tokyo.n-n.cmds.sync", qos: .userInitiated)
    private let codec = SyncCodec()
    private let limiter = SyncRateLimiter()
    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    private var changesCancellable: AnyCancellable?
    private var usageCancellable: AnyCancellable?
    private var usageStateScheduled = false
    private var codeTimer: Timer?
    private var codeFailures = 0

    private var screenTimer: Timer?
    /// Last snapshot read per streamed pane; skips per-client work when nothing changed.
    private var lastSnapshot: [String: ScreenSnapshot] = [:]

    private var stateScheduled = false
    private var lastStateSentAt = Date.distantPast
    private var lastStateData: Data?

    private init() {
        macName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        UserDefaults.standard.register(defaults: [Self.enabledDefaultsKey: true])
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledDefaultsKey)
            newValue ? start() : stop()
        }
    }

    /// True while the pairing window is shown. Pairing codes are rejected otherwise, which keeps
    /// the 6-digit code out of reach of guessing except while the user is actually pairing.
    /// Closing the window retires the code.
    var isPairingOpen = false {
        didSet {
            if oldValue && !isPairingOpen { rotateCode() }
        }
    }

    var connectedDevices: [ConnectedDevice] {
        clients.values.filter(\.authenticated)
            .sorted { $0.connectedAt < $1.connectedAt }
            .map { ConnectedDevice(name: $0.deviceName, host: $0.connection.remoteHost, since: $0.connectedAt,
                                   tokenHash: $0.tokenHash ?? "") }
    }

    // MARK: - Lifecycle

    func startIfEnabled() {
        if isEnabled { start() }
    }

    func start() {
        guard listener == nil else { return }
        // Isolated test instances: no Bonjour advert, no port.
        guard !CmdsEnv.isSyncDisabled() else {
            statusText = "Disabled (\(CmdsEnv.syncDisabled))"
            didChange()
            return
        }
        rotateCode()
        startListener(port: SyncProtocol.defaultPort)
        changesCancellable = AppController.shared.changes.sink { [weak self] change in
            self?.handle(change)
        }
        usageCancellable = AppController.shared.usageChanges.sink { [weak self] in
            self?.usageDidChange()
        }
    }

    func stop() {
        changesCancellable = nil
        usageCancellable = nil
        listener?.cancel()
        listener = nil
        port = nil
        codeTimer?.invalidate()
        codeTimer = nil
        for client in clients.values { client.connection.close() }
        clients.removeAll()
        stopScreenTimer()
        lastStateData = nil
        statusText = "Stopped"
        didChange()
    }

    /// Draws a new code (on demand, every 10 minutes and after each successful pairing).
    func rotateCode() {
        pairingCode = PairingToken.generateCode()
        codeExpiresAt = Date().addingTimeInterval(Self.codeLifetime)
        codeFailures = 0
        codeTimer?.invalidate()
        codeTimer = Timer.scheduledTimer(withTimeInterval: Self.codeLifetime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.rotateCode() }
        }
        #if DEBUG
        // Debug builds only, for local end-to-end testing. Never log tokens.
        syncLog.debug("pairing code: \(self.pairingCode, privacy: .public)")
        #endif
        didChange()
    }

    /// Forgets every paired device and disconnects them.
    /// Drops sessions authenticated with any of `tokenHashes`.
    private func deauthorize(tokenHashes: [String], reason: String) {
        guard !tokenHashes.isEmpty else { return }
        for client in clients.values where client.authenticated {
            guard let hash = client.tokenHash,
                  tokenHashes.contains(where: { SyncDeviceStore.digestsEqual($0, hash) }) else { continue }
            client.authenticated = false
            client.subscribed = []
            sendError(.invalidToken, reason, to: client, close: true)
        }
        pruneScreenCache()
    }

    func revokeAllDevices() {
        store.revokeAll()
        for client in clients.values where client.authenticated {
            // Stop streaming to it at once; the error is the last frame it gets.
            client.authenticated = false
            client.subscribed = []
            sendError(.invalidToken, "this device was unpaired on the Mac", to: client, close: true)
        }
        pruneScreenCache()
        rotateCode()
    }

    private func startListener(port requested: UInt16?) {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        let params = NWParameters(tls: nil, tcp: tcp)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = Self.maxFrameBytes
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.includePeerToPeer = true

        let nwPort = requested.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            if requested != nil { return startListener(port: nil) }
            statusText = "Failed: \(error.localizedDescription)"
            syncLog.error("listener failed: \(error.localizedDescription, privacy: .public)")
            didChange()
            return
        }
        listener.service = NWListener.Service(name: macName, type: SyncProtocol.bonjourServiceType, domain: nil,
                                              txtRecord: NWTXTRecord(SyncProtocol.txtRecord(macName: macName)))
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let listener, self.listener === listener else { return }
                    self.listenerStateChanged(state, listener: listener, requestedPort: requested)
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.listener != nil else { return connection.cancel() }
                    self.accept(connection)
                }
            }
        }
        self.listener = listener
        statusText = "Starting…"
        listener.start(queue: queue)
    }

    private func listenerStateChanged(_ state: NWListener.State, listener: NWListener, requestedPort: UInt16?) {
        switch state {
        case .ready:
            port = listener.port?.rawValue
            statusText = "Listening on port \(port.map(String.init) ?? "?")"
            syncLog.notice("listening on port \(self.port ?? 0, privacy: .public)")
        case .failed(let error):
            listener.cancel()
            self.listener = nil
            port = nil
            if requestedPort != nil {
                syncLog.notice("port \(requestedPort ?? 0, privacy: .public) unavailable (\(error.localizedDescription, privacy: .public)), using any port")
                startListener(port: nil)
                return
            }
            statusText = "Failed: \(error.localizedDescription)"
            syncLog.error("listener failed: \(error.localizedDescription, privacy: .public)")
        case .waiting(let error):
            statusText = "Waiting: \(error.localizedDescription)"
        default:
            break
        }
        didChange()
    }

    // MARK: - Connections

    private func accept(_ nwConnection: NWConnection) {
        guard clients.count < Self.maxConnections else {
            nwConnection.cancel()
            return
        }
        let connection = SyncConnection(connection: nwConnection, queue: queue,
                                        onFrame: { [weak self] conn, data in self?.received(data, from: conn) },
                                        onClose: { [weak self] conn in self?.closed(conn) })
        // One host must not fill every slot with connections that never say hello.
        let pendingFromHost = clients.values.filter { !$0.authenticated && $0.connection.remoteHost == connection.remoteHost }
        guard pendingFromHost.count < Self.maxPendingPerHost else {
            nwConnection.cancel()
            return
        }
        let client = Client(connection: connection)
        clients[connection.id] = client
        let timer = DispatchWorkItem { [weak client] in
            guard let client, !client.authenticated else { return }
            client.connection.close()
        }
        client.helloTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.helloTimeout, execute: timer)
        connection.start()
    }

    private func closed(_ connection: SyncConnection) {
        guard let client = clients.removeValue(forKey: connection.id) else { return }
        client.helloTimer?.cancel()
        pruneScreenCache()
        if client.authenticated { didChange() }
    }

    private func received(_ data: Data, from connection: SyncConnection) {
        guard let client = clients[connection.id], !client.closing else { return }
        guard data.count <= Self.maxFrameBytes else {
            sendError(.badRequest, "frame too large", to: client, close: true)
            return
        }
        let message: ClientMessage
        do {
            message = try codec.decodeClientMessage(data)
        } catch let error as UnknownSyncMessageType {
            sendError(.badRequest, "unknown message type: \(error.type.prefix(40))", to: client, close: !client.authenticated)
            return
        } catch {
            sendError(.badRequest, "malformed message", to: client, close: !client.authenticated)
            return
        }

        guard client.authenticated else {
            if case .hello(let hello) = message {
                authenticate(client, hello: hello)
            } else {
                sendError(.notAuthenticated, "send hello first", to: client, close: true)
            }
            return
        }

        switch message {
        case .hello:
            sendError(.badRequest, "already authenticated", to: client)
        case .ping(let ping):
            send(.pong(.init(nonce: ping.nonce)), to: client)
        case .subscribe(let sub):
            subscribe(client, paneIDs: sub.paneIDs)
        case .requestScreen(let req):
            if let msg = client.streamer.fullScreen(paneID: req.paneID) {
                send(msg, to: client)
            } else if let snapshot = snapshot(paneID: req.paneID) {
                if let msg = client.streamer.update(paneID: req.paneID, snapshot: snapshot) { send(msg, to: client) }
            } else {
                sendError(.notFound, "pane not found: \(req.paneID.prefix(64))", to: client)
            }
        case .input(let input):
            let size = input.text.utf8.count
            guard size <= Self.maxInputBytes else {
                sendError(.badRequest, "input too large (max \(Self.maxInputBytes) bytes per message)", to: client)
                return
            }
            guard client.spendInput(size) else {
                sendError(.rateLimited, "too much input; slow down", to: client)
                return
            }
            // Keystrokes from the phone are typed (no bracketed paste); multi-line text keeps the paste path.
            if input.text.contains(where: \.isNewline) {
                perform(client) { try AppController.shared.sendText(paneID: input.paneID, text: input.text) }
            } else {
                perform(client) { try AppController.shared.typeText(paneID: input.paneID, text: input.text) }
            }
        case .key(let key):
            guard client.spendInput(8) else {
                sendError(.rateLimited, "too much input; slow down", to: client)
                return
            }
            guard let bytes = key.key.terminalBytes(applicationCursor: false) else {
                sendError(.badRequest, "unknown key: \(key.key.rawValue.prefix(20))", to: client)
                return
            }
            let text = String(decoding: bytes, as: UTF8.self)
            perform(client) { try AppController.shared.sendText(paneID: key.paneID, text: text) }
        case .selectWorkspace(let select):
            perform(client) { try AppController.shared.selectWorkspace(id: select.id) }
        case .focusPane(let focus):
            perform(client) { try AppController.shared.focusPane(id: focus.id) }
        }
    }

    /// Runs an AppController call; API errors become `error` messages. IDs are always passed
    /// non-nil, so the controller never falls back to the focused pane for remote requests.
    private func perform(_ client: Client, _ body: () throws -> Void) {
        do {
            try body()
        } catch let error as RPCError {
            let code: SyncErrorCode = error.code == 404 ? .notFound : .badRequest
            sendError(code, error.message, to: client)
        } catch {
            sendError(.internalError, "\(error)", to: client)
        }
    }

    // MARK: - Pairing

    private func authenticate(_ client: Client, hello: ClientMessage.Hello) {
        let host = client.connection.remoteHost
        // Tokens are compared by hash: the store only knows hashes.
        var hashed = hello
        if let token = hello.token, !token.isEmpty { hashed.token = SyncDeviceStore.hash(token) }
        let knownHashes = store.tokenHashes
        let tokenValid = hashed.token.map { !$0.isEmpty && PairingToken.matchesAny($0, in: knownHashes) } ?? false

        if !tokenValid, let wait = limiter.lockout(host: host) {
            sendError(.rateLimited, "too many failed attempts; try again in \(Int(wait.rounded(.up))) s",
                      to: client, close: true)
            return
        }

        // Codes are only accepted while the pairing window is open (tokens always are).
        let openCode = isPairingOpen ? pairingCode : nil
        switch PairingAuthenticator.evaluate(hashed, currentCode: openCode, knownTokens: knownHashes) {
        case .accepted(let token, let isNewToken):
            let name = Self.sanitize(hello.deviceName)
            let plainToken: String
            if isNewToken {
                plainToken = token
                let deviceID = hello.deviceID.map { String($0.prefix(128)) }
                // Re-pairing replaces the device's old token; sessions still using it must lose access too.
                let replaced = deviceID.map { store.tokenHashes(deviceID: $0) } ?? []
                store.add(token: token, deviceName: name, deviceID: deviceID)
                deauthorize(tokenHashes: replaced, reason: "this device was paired again")
                limiter.recordSuccess(host: host)
                rotateCode()
                syncLog.notice("paired new device \(name, privacy: .public) from \(host, privacy: .public)")
            } else {
                plainToken = hello.token ?? ""
                store.touch(tokenHash: token, name: name)
            }
            client.helloTimer?.cancel()
            client.authenticated = true
            client.deviceName = name
            client.tokenHash = SyncDeviceStore.hash(plainToken)
            send(.welcome(.init(macName: macName, token: plainToken)), to: client)
            send(.state(currentState()), to: client)
            // This client may now be ahead of the last broadcast; never skip the next one as a duplicate.
            lastStateData = nil
            didChange()
        case .rejected(let error):
            if error.code == .invalidPairingCode || error.code == .invalidToken {
                limiter.recordFailure(host: host)
                syncLog.notice("rejected pairing from \(host, privacy: .public): \(error.code.rawValue, privacy: .public)")
            }
            if error.code == .invalidPairingCode {
                codeFailures += 1
                if codeFailures >= Self.maxFailuresPerCode { rotateCode() }
            }
            sendError(error.code, error.message, to: client, close: true)
        }
    }

    private static func sanitize(_ name: String) -> String {
        let cleaned = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "iOS device" : String(cleaned.prefix(64))
    }

    // MARK: - State

    private func handle(_ change: StateChange) {
        guard clients.values.contains(where: \.authenticated) else {
            lastStateData = nil
            return
        }
        if case .notification(let workspaceID, let paneID, let title, let body) = change {
            broadcast(.notification(.init(paneID: paneID, workspaceID: workspaceID,
                                          title: title ?? "cmds", body: body)))
        }
        scheduleState()
    }

    /// Coalesces state broadcasts to at most one per `stateInterval`.
    private func scheduleState() {
        guard !stateScheduled else { return }
        stateScheduled = true
        let delay = max(0, Self.stateInterval - Date().timeIntervalSince(lastStateSentAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.sendState() }
        }
    }

    private func sendState() {
        stateScheduled = false
        lastStateSentAt = Date()
        guard let data = try? codec.encode(.state(currentState())), data != lastStateData else { return }
        lastStateData = data
        for client in clients.values where client.authenticated { client.connection.send(data) }
    }

    private func currentState() -> ServerMessage.State {
        ServerMessage.State(workspaces: AppController.shared.listWorkspaces(), system: AppController.shared.systemStats)
    }

    /// A usage sample changes CPU/memory figures in nearly every `state`; push them at most every
    /// `usageStateInterval` (any other state push carries them too), and only while a phone is connected.
    private func usageDidChange() {
        guard !usageStateScheduled, clients.values.contains(where: \.authenticated) else { return }
        usageStateScheduled = true
        let delay = max(0, Self.usageStateInterval - Date().timeIntervalSince(lastStateSentAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.usageStateScheduled = false
                guard self.clients.values.contains(where: \.authenticated) else { return }
                self.scheduleState()
            }
        }
    }

    // MARK: - Screens

    private func subscribe(_ client: Client, paneIDs: [String]) {
        var wanted = Set(paneIDs.prefix(Self.maxSubscribedPanes))
        let added = wanted.subtracting(client.subscribed)
        for paneID in added {
            client.streamer.reset(paneID: paneID)
            if let snapshot = snapshot(paneID: paneID) {
                if let msg = client.streamer.update(paneID: paneID, snapshot: snapshot) { send(msg, to: client) }
            } else {
                wanted.remove(paneID)
                sendError(.notFound, "pane not found or not a terminal: \(paneID.prefix(64))", to: client)
            }
        }
        client.subscribed = wanted
        // Keeps per-pane seq for unsubscribed panes (CmdsCore >= 654204a), so a later
        // re-subscribe is not taken as stale by the phone's ScreenMirror.
        client.streamer.retain(paneIDs: wanted)
        pruneScreenCache()
        if subscribedPanes.isEmpty { stopScreenTimer() } else { startScreenTimer() }
    }

    private var subscribedPanes: Set<String> {
        clients.values.reduce(into: Set<String>()) { if $1.authenticated { $0.formUnion($1.subscribed) } }
    }

    private func pruneScreenCache() {
        let panes = subscribedPanes
        lastSnapshot = lastSnapshot.filter { panes.contains($0.key) }
        if panes.isEmpty { stopScreenTimer() }
    }

    private func startScreenTimer() {
        guard screenTimer == nil else { return }
        let timer = Timer(timeInterval: Self.screenInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenTick() }
        }
        timer.tolerance = Self.screenInterval / 5
        RunLoop.main.add(timer, forMode: .common)
        screenTimer = timer
    }

    private func stopScreenTimer() {
        screenTimer?.invalidate()
        screenTimer = nil
    }

    private func screenTick() {
        let panes = subscribedPanes
        guard !panes.isEmpty else { return stopScreenTimer() }
        for paneID in panes {
            guard let snapshot = snapshot(paneID: paneID) else {
                lastSnapshot[paneID] = nil
                continue
            }
            // Compare the whole snapshot: a cursor move alone (e.g. ← on a prompt) must reach the phone.
            if lastSnapshot[paneID] == snapshot { continue }
            lastSnapshot[paneID] = snapshot
            for client in clients.values where client.authenticated && client.subscribed.contains(paneID) {
                if let msg = client.streamer.update(paneID: paneID, snapshot: snapshot) { send(msg, to: client) }
            }
        }
    }

    /// Current screen of a pane, or nil if it does not exist / is not a terminal.
    private func snapshot(paneID: String) -> ScreenSnapshot? {
        guard !paneID.isEmpty, let state = try? AppController.shared.screenState(paneID: paneID) else { return nil }
        var lines = state.text.components(separatedBy: "\n").map { line -> String in
            var line = line
            if line.hasSuffix("\r") { line.removeLast() }
            while line.hasSuffix(" ") { line.removeLast() }
            return line
        }
        let rows = max(1, state.grid?.rows ?? lines.count)
        let cols = max(1, state.grid?.cols ?? lines.reduce(20) { max($0, $1.count) })
        if lines.count > rows { lines.removeLast(lines.count - rows) }
        if lines.count < rows { lines += Array(repeating: "", count: rows - lines.count) }
        return ScreenSnapshot(rows: rows, cols: cols, lines: lines,
                              cursorRow: state.cursor?.row, cursorCol: state.cursor?.col)
    }

    // MARK: - Sending

    private func send(_ message: ServerMessage, to client: Client, close: Bool = false) {
        guard let data = try? codec.encode(message) else { return }
        client.connection.send(data, thenClose: close)
    }

    private func sendError(_ code: SyncErrorCode, _ message: String, to client: Client, close: Bool = false) {
        if close { client.closing = true }
        send(.error(.init(code: code, message: message)), to: client, close: close)
    }

    private func broadcast(_ message: ServerMessage) {
        guard let data = try? codec.encode(message) else { return }
        for client in clients.values where client.authenticated { client.connection.send(data) }
    }

    private func didChange() {
        NotificationCenter.default.post(name: .syncServerDidChange, object: self)
    }
}
