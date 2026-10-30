import CmdsCore
import SwiftUI

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
