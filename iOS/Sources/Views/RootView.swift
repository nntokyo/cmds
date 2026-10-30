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
