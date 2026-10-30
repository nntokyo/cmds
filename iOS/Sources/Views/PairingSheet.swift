import CmdsCore
import SwiftUI

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
