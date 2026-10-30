import CmdsCore
import SwiftUI

struct RootView: View {
    @Environment(CompanionClient.self) private var client
    @Environment(MacBrowser.self) private var browser

    var body: some View {
        Group {
            if client.target == nil {
                ConnectView()
            } else {
                MainView()
            }
        }
        .sheet(isPresented: pairingBinding) {
            PairingSheet()
                .environment(client)
                .environment(browser)
                .interactiveDismissDisabled()
        }
    }

    /// Shown while pairing is needed and while a pairing attempt is in flight.
    private var pairingBinding: Binding<Bool> {
        Binding(
            get: { client.status.needsPairing || (client.isPairing && !client.status.isLive) },
            set: { presented in if !presented, client.status.needsPairing { client.disconnect() } }
        )
    }
}

/// Mac picker: pairing QR code, Bonjour results, recent Macs, manual entry, demo mode.
struct ConnectView: View {
    @Environment(CompanionClient.self) private var client
    @Environment(MacBrowser.self) private var browser
    @State private var manualHost = ""
    @State private var recents = RecentMacs.load()
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        scanning = true
                    } label: {
                        Label("Scan Pairing Code", systemImage: "qrcode.viewfinder")
                    }
                } footer: {
                    Text("On the Mac, choose cmds › Pair iPhone/iPad… and scan the QR code it shows.")
                }

                Section {
                    if browser.macs.isEmpty {
                        HStack(spacing: 10) {
                            if browser.isBrowsing { ProgressView() }
                            Text(browser.error ?? String(localized: "Looking for Macs running cmds…"))
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(browser.macs) { mac in
                        macRow(mac, systemImage: "desktopcomputer")
                    }
                } header: {
                    Text("On this network")
                } footer: {
                    Text("Enable iOS Sync in cmds on your Mac. The first connection to a Mac needs its pairing code.")
                }

                let otherRecents = recents.filter { r in !browser.macs.contains { $0.id == r.id } }
                if !otherRecents.isEmpty {
                    Section("Recent") {
                        ForEach(otherRecents) { mac in
                            macRow(mac, systemImage: "clock")
                        }
                        .onDelete { offsets in
                            for i in offsets {
                                RecentMacs.forget(otherRecents[i])
                                PairingStore.delete(for: otherRecents[i].id)
                            }
                            recents = RecentMacs.load()
                        }
                    }
                }

                Section {
                    HStack {
                        TextField("host or host:port", text: $manualHost)
                            .accessibilityIdentifier("manualHost")
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.go)
                            .onSubmit(connectManual)
                        Button("Connect", action: connectManual)
                            .disabled(MacTarget.manual(manualHost) == nil)
                    }
                } header: {
                    Text("Manual")
                } footer: {
                    Text("Default port \(String(SyncProtocol.defaultPort)).")
                }

                Section {
                    Button {
                        client.connect(to: .mock)
                    } label: {
                        Label("Try with demo data", systemImage: "sparkles.tv")
                    }
                }
            }
            .navigationTitle("Connect to Mac")
            .onAppear {
                browser.start()
                recents = RecentMacs.load()
            }
            .onDisappear { browser.stop() }
            .sheet(isPresented: $scanning) {
                PairingCodeScanner { payload in
                    client.pair(with: payload, target: .pairingTarget(for: payload, discovered: browser.macs))
                }
            }
        }
    }

    private func macRow(_ mac: MacTarget, systemImage: String) -> some View {
        Button {
            client.connect(to: mac)
        } label: {
            HStack {
                Image(systemName: systemImage)
                    .frame(width: 28)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text(mac.displayName).foregroundStyle(.primary)
                    Text(mac.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if PairingStore.isPaired(mac.id) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Paired")
                }
            }
        }
    }

    private func connectManual() {
        guard let target = MacTarget.manual(manualHost) else { return }
        client.connect(to: target)
    }
}

/// Pairing with the current Mac. Preferred: scan its QR code (pins the full fingerprint and carries the
/// code). Without a camera: read the identity the Mac presents, let the user compare it with the Mac's
/// pairing window, then send the code over a connection pinned to it. A changed identity is a hard stop.
struct PairingSheet: View {
    @Environment(CompanionClient.self) private var client
    @Environment(MacBrowser.self) private var browser
    @State private var code = ""
    @State private var scanning = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    switch client.status {
                    case .pairingRequired(let message):
                        choice(message)
                    case .checkingIdentity:
                        ProgressView("Reading the Mac's identity…")
                            .padding(.top, 40)
                    case .confirmIdentity(let fingerprint):
                        confirm(fingerprint)
                    case .enterCode(let message):
                        codeEntry(message)
                    case .identityMismatch(let message):
                        mismatch(message)
                    default:
                        progress
                    }
                }
                .padding(24)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Pair with Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { client.disconnect() }
                }
            }
            .sheet(isPresented: $scanning) {
                PairingCodeScanner { payload in
                    client.pair(with: payload, target: .pairingTarget(for: payload, discovered: browser.macs))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func choice(_ message: String?) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.laptopcomputer")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Pair with “\(client.macName)”")
                .font(.headline)
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Text("On the Mac, choose cmds › Pair iPhone/iPad…, then scan the QR code it shows.")
                .multilineTextAlignment(.center)
            Button {
                scanning = true
            } label: {
                Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if client.target?.kind != .mock {
                Button("Pair Without Camera") { client.checkIdentity() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func confirm(_ fingerprint: SyncFingerprint) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Compare with your Mac")
                .font(.headline)
            Text("The pairing window on “\(client.macName)” shows “Mac identity”. It must read exactly:")
                .multilineTextAlignment(.center)
            Text(fingerprint.short)
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityIdentifier("pairingFingerprint")
            Button("It Matches") { client.confirmIdentity(fingerprint) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Button("It Doesn't Match", role: .destructive) { client.rejectIdentity() }
            Text("Scanning the QR code is safer: it checks the Mac's full identity.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func codeEntry(_ message: String?) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.laptopcomputer")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Enter the 6-digit code shown in cmds on “\(client.macName)”.")
                .multilineTextAlignment(.center)
            if let pin = client.pairingPin {
                Label("Mac identity \(pin.short)", systemImage: "checkmark.shield.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
            TextField("000000" as String, text: $code)
                .accessibilityIdentifier("pairingCode")
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .frame(maxWidth: 220)
                .padding(.vertical, 8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .onChange(of: code) { _, new in
                    let digits = String(new.filter(\.isNumber).prefix(SyncProtocol.pairingCodeLength))
                    if digits != new { code = digits }
                    if digits.count == SyncProtocol.pairingCodeLength { submit() }
                }
            if let message {
                Text(message).foregroundStyle(.red).font(.callout)
            }
            Button("Pair", action: submit)
                .buttonStyle(.borderedProminent)
                .disabled(code.count != SyncProtocol.pairingCodeLength)
        }
        .onAppear { focused = true }
    }

    private func mismatch(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text("This Mac's identity changed — re-pair")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(message)
                .multilineTextAlignment(.center)
            Button("Re-pair") { client.unpair() }
                .buttonStyle(.borderedProminent)
            Button("Cancel") { client.disconnect() }
        }
    }

    private var progress: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Pairing with “\(client.macName)”…")
            if case .reconnecting(_, let reason?) = client.status {
                Text(reason).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(.top, 40)
    }

    private func submit() {
        guard code.count == SyncProtocol.pairingCodeLength else { return }
        client.submitPairingCode(code)
        code = ""
    }
}

#if DEBUG
/// Debug builds only: the connection diagnostics as a row a UI test driver can read
/// (`accessibilityIdentifier` "syncDiagnostics"; label and value are the summary).
struct ConnectionDiagnosticsRow: View {
    @Environment(CompanionClient.self) private var client

    var body: some View {
        Text(client.diagnostics.summary)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("syncDiagnostics")
            .accessibilityValue(client.diagnostics.summary)
    }
}

/// Debug builds only: forces the transport (as `-cmdsTransport` does) and reconnects.
struct TransportModeMenu: View {
    @Environment(CompanionClient.self) private var client

    var body: some View {
        Menu {
            ForEach(TransportMode.allCases, id: \.self) { mode in
                Button {
                    TransportMode.set(mode)
                    if let target = client.target { client.connect(to: target) }
                } label: {
                    // Debug only: not localized, and UI test drivers tap these labels.
                    if client.diagnostics.mode == mode {
                        Label { Text(verbatim: "Transport: \(mode.rawValue)") } icon: { Image(systemName: "checkmark") }
                    } else {
                        Text(verbatim: "Transport: \(mode.rawValue)")
                    }
                }
                .accessibilityIdentifier("transport.\(mode.rawValue)")
            }
        } label: {
            Label { Text(verbatim: "Transport (Debug)") } icon: { Image(systemName: "ladybug") }
        }
        .accessibilityIdentifier("debugTransport")
    }
}
#endif

/// Small dot + label describing the connection.
struct ConnectionStatusBadge: View {
    @Environment(CompanionClient.self) private var client

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(client.status.isLive ? [client.macName, client.linkPath?.label].compactMap { $0 }.joined(separator: " · ") : client.status.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connectionStatus")
        .accessibilityValue(accessibilityValue)
    }

    /// Debug builds: the full `ConnectionDiagnostics` summary (mode, path, stage per path, last error) for UI
    /// test drivers. Release: the path, or the last error while not connected.
    private var accessibilityValue: String {
        #if DEBUG
        return client.diagnostics.summary
        #else
        if client.status.isLive { return client.linkPath?.label ?? "" }
        return client.diagnostics.lastError ?? ""
        #endif
    }

    private var color: Color {
        switch client.status {
        case .connected: return .green
        case .connecting, .authenticating, .reconnecting: return .orange
        default: return .red
        }
    }
}
