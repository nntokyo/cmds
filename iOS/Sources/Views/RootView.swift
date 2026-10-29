import CmdsCore
import SwiftUI

struct RootView: View {
    @Environment(CompanionClient.self) private var client

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
                .interactiveDismissDisabled()
        }
    }

    private var pairingBinding: Binding<Bool> {
        Binding(
            get: { if case .pairingRequired = client.status { return true } else { return false } },
            set: { presented in if !presented, case .pairingRequired = client.status { client.disconnect() } }
        )
    }
}

/// Mac picker: Bonjour results, recent Macs, manual entry, demo mode.
struct ConnectView: View {
    @Environment(CompanionClient.self) private var client
    @Environment(MacBrowser.self) private var browser
    @State private var manualHost = ""
    @State private var recents = RecentMacs.load()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if browser.macs.isEmpty {
                        HStack(spacing: 10) {
                            if browser.isBrowsing { ProgressView() }
                            Text(browser.error ?? "Looking for Macs running cmds…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(browser.macs) { mac in
                        macRow(mac, systemImage: "desktopcomputer")
                    }
                } header: {
                    Text("On this network")
                } footer: {
                    Text("Enable “iOS companion” in cmds on your Mac. The Mac shows a 6-digit code the first time you connect.")
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
                                TokenStore.deleteToken(for: otherRecents[i].id)
                            }
                            recents = RecentMacs.load()
                        }
                    }
                }

                Section {
                    HStack {
                        TextField("host or host:port", text: $manualHost)
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
                if TokenStore.token(for: mac.id) != nil {
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

struct PairingSheet: View {
    @Environment(CompanionClient.self) private var client
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "lock.laptopcomputer")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("Enter the 6-digit code shown in cmds on “\(client.macName)”.")
                    .multilineTextAlignment(.center)
                TextField("000000", text: $code)
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
                if case .pairingRequired(let message?) = client.status {
                    Text(message).foregroundStyle(.red).font(.callout)
                }
                Button("Pair", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(code.count != SyncProtocol.pairingCodeLength)
                Spacer()
            }
            .padding(24)
            .navigationTitle("Pair with Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { client.disconnect() }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func submit() {
        guard code.count == SyncProtocol.pairingCodeLength else { return }
        client.submitPairingCode(code)
        code = ""
    }
}

/// Small dot + label describing the connection.
struct ConnectionStatusBadge: View {
    @Environment(CompanionClient.self) private var client

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(client.status.isLive ? client.macName : client.status.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch client.status {
        case .connected: return .green
        case .connecting, .authenticating, .reconnecting: return .orange
        default: return .red
        }
    }
}
