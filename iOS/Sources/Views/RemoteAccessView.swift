import CmdsCore
import CmdsSSH
import SwiftUI
import UIKit

/// Settings › Remote Access via SSH for the current Mac (docs/SYNC.md "Remote access via SSH"): the relay
/// host the Mac forwards to, this phone's public key for the relay's authorized_keys, and the relay's host
/// key (confirmed by fingerprint on first use, then pinned). The app never asks for a password.
struct RemoteAccessView: View {
    let targetID: String
    let macName: String
    @Environment(\.dismiss) private var dismiss

    @State private var config = RemoteAccessConfig()
    @State private var portText = "22"
    @State private var relayPortText = String(SyncRemote.defaultRelayPort)
    @State private var publicKeyLine: String?
    @State private var keyError = false
    @State private var checking = false
    @State private var checkResult: String?
    @State private var checkOK = false
    /// Host key presented on first use and the `host:port` that presented it, waiting for confirmation.
    @State private var presentedHostKey: (key: String, hostKeyID: String)?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Use Remote Access", isOn: $config.enabled)
                } footer: {
                    Text("When “\(macName)” cannot be reached over Wi‑Fi or Bluetooth, connect through an SSH server you use (the relay host). On the Mac, turn on cmds › Remote Access via SSH… for the same host. Pair on the local network first; the connection stays encrypted end to end and pinned to the Mac.")
                }

                Section("Relay Host") {
                    TextField("Host name or address", text: $config.endpoint.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("User", text: $config.endpoint.user)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    LabeledContent("SSH port") {
                        TextField("22" as String, text: $portText).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Relay port") {
                        TextField(String(SyncRemote.defaultRelayPort), text: $relayPortText)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                }

                Section {
                    if let publicKeyLine {
                        Text(publicKeyLine)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = publicKeyLine }
                        ShareLink(item: publicKeyLine)
                    } else if keyError {
                        Text("This device's SSH key could not be stored in the Keychain.").foregroundStyle(.red)
                    }
                } header: {
                    Text("This Device's Key")
                } footer: {
                    Text("Add this line to ~/.ssh/authorized_keys of that user on the relay host (replace an older cmds line for this device: it lists the relay ports of all your Macs). It only allows forwarding to those ports: no shell. The private key never leaves this device.")
                }

                Section {
                    if let pinned = config.pinnedHostKey {
                        LabeledContent("Host key", value: SSHKeys.fingerprint(openSSHPublicKey: pinned) ?? "?")
                            .font(.caption.monospaced())
                        Button("Forget Host Key", role: .destructive) {
                            config.hostKey = nil
                            config.hostKeyFor = nil
                            persist()
                        }
                    }
                    if let presented = presentedHostKey {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("First connection to \(presented.hostKeyID). Compare this fingerprint with the relay host's key (on the relay: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub).")
                                .font(.callout)
                            Text(SSHKeys.fingerprint(openSSHPublicKey: presented.key) ?? "?")
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        }
                        Button("It Matches — Trust This Host") { trust(presented) }
                        Button("Cancel", role: .cancel) { presentedHostKey = nil }
                    }
                    Button {
                        Task { await check() }
                    } label: {
                        HStack {
                            Text("Check Connection")
                            if checking { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(checking || !fieldsValid || publicKeyLine == nil)
                    if let checkResult {
                        Text(checkResult).font(.callout).foregroundStyle(checkOK ? .green : .red)
                    }
                } header: {
                    Text("Relay Host Key")
                } footer: {
                    Text("Remote access is used only after the host key is confirmed. A different key later is refused.")
                }
            }
            .navigationTitle("Remote Access via SSH")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        _ = applyFields()
                        persist()
                        dismiss()
                    }
                }
            }
            .onAppear(perform: load)
            .onChange(of: relayPortText) { refreshKeyLine() }
            // A pending confirmation belongs to the host and port that presented the key.
            .onChange(of: config.endpoint.host) { presentedHostKey = nil }
            .onChange(of: portText) { presentedHostKey = nil }
        }
    }

    private func load() {
        config = RemoteAccessStore.config(for: targetID) ?? RemoteAccessConfig()
        portText = String(config.endpoint.port)
        relayPortText = String(config.endpoint.relayPort)
        refreshKeyLine()
    }

    private func refreshKeyLine() {
        guard let key = PhoneSSHKey.loadOrCreate() else {
            keyError = true
            publicKeyLine = nil
            return
        }
        let relayPort = UInt16(relayPortText) ?? SyncRemote.defaultRelayPort
        publicKeyLine = PhoneSSHKey.restrictedAuthorizedKeysLine(key.publicKey, relayPort: relayPort)
    }

    private var fieldsValid: Bool {
        guard let port = UInt16(portText), port > 0, let relay = UInt16(relayPortText), relay > 0 else { return false }
        return !config.endpoint.host.trimmingCharacters(in: .whitespaces).isEmpty
            && !config.endpoint.user.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Copies the text fields into `config`; false if a port is invalid or a field is empty.
    @discardableResult
    private func applyFields() -> Bool {
        config.endpoint.host = config.endpoint.host.trimmingCharacters(in: .whitespaces)
        config.endpoint.user = config.endpoint.user.trimmingCharacters(in: .whitespaces)
        guard let port = UInt16(portText), port > 0, let relay = UInt16(relayPortText), relay > 0 else { return false }
        config.endpoint.port = port
        config.endpoint.relayPort = relay
        return config.endpoint.isComplete
    }

    private func persist() {
        RemoteAccessStore.save(config, for: targetID)
    }

    private func trust(_ presented: (key: String, hostKeyID: String)) {
        presentedHostKey = nil
        // Only for the endpoint that presented it (the fields may have changed since).
        guard applyFields(), config.hostKeyID == presented.hostKeyID else { return }
        config.hostKey = presented.key
        config.hostKeyFor = presented.hostKeyID
        persist()
        Task { await check() }
    }

    /// Logs in to the relay and opens the channel to the Mac's forwarded port (nothing is sent to the Mac).
    private func check() async {
        guard applyFields(), let key = PhoneSSHKey.load() else { return }
        persist()
        checking = true
        checkResult = nil
        presentedHostKey = nil
        defer { checking = false }
        let endpoint = config.endpoint
        let hostKeyID = config.hostKeyID
        do {
            let tunnel = try await SSHTunnel.connect(to: endpoint, key: key, hostKeyPin: config.pinnedHostKey)
            defer { tunnel.close() }
            _ = try await tunnel.openForward()
            checkOK = true
            checkResult = String(localized: "The relay host accepted this device and the Mac's forwarded port answers.")
        } catch SSHTunnelError.unknownHostKey(let presented) {
            // Ignore it if the fields changed while connecting.
            if applyFields(), config.hostKeyID == hostKeyID { presentedHostKey = (presented, hostKeyID) }
        } catch {
            checkOK = false
            checkResult = (error as? SSHTunnelError)?.localizedText ?? error.localizedDescription
        }
    }
}
