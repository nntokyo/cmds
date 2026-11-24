import CmdsCore
import SwiftUI

/// A Mac browser pane on the phone: the same page in a web view, loaded by the phone itself (its own network and
/// cookies, not the Mac's). Pages served by the Mac (localhost) cannot be reached from the phone.
struct BrowserPaneView: View {
    @Environment(CompanionClient.self) private var client
    let pane: PaneInfo
    @State private var reloadToken = 0
    @State private var loading = false

    private var title: String { pane.title.isEmpty ? String(localized: "Browser") : DefaultTitle.localized(pane.title) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "globe").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let url = pane.url {
                        Text(url).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                if case .load(let url) = BrowserPaneURL.resolve(pane.url) {
                    Button { reloadToken += 1 } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Reload")
                    Link(destination: url) { Image(systemName: "safari") }
                        .accessibilityLabel("Open in Safari")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            switch BrowserPaneURL.resolve(pane.url) {
            case .load(let url):
                WebPageView(content: .url(url), reloadToken: reloadToken) { loading = $0 }
                    .overlay { if loading { ProgressView().controlSize(.large) } }
            case .macOnly where client.macSnapshotsPages:
                PageSnapshotView(pane: pane)
            case .macOnly:
                ContentUnavailableView {
                    Label(title, systemImage: "globe")
                } description: {
                    Text("This page is served by the Mac (localhost or a file) and cannot be opened on the phone.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// A page only the Mac can load (its localhost): a picture the Mac takes of it (`SyncFeature.pageSnapshots`, #174 G25),
/// as the pane shows it or at a phone, tablet or desktop size (the Mac loads it again off screen; its pane does not
/// change). Pinch to zoom; the arrow takes a new one.
struct PageSnapshotView: View {
    @Environment(CompanionClient.self) private var client
    let pane: PaneInfo
    @State private var size = SyncPageSnapshot.asShown

    static func label(_ size: String) -> String {
        switch size {
        case SyncPageSnapshot.asShown: return String(localized: "As on Mac", comment: "page picture: the pane as the Mac shows it")
        case "iphone": return String(localized: "iPhone")
        case "ipad": return String(localized: "iPad")
        default: return String(localized: "Desktop", comment: "page picture at a desktop size")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(String(localized: "Size"), selection: $size) {
                    ForEach(SyncPageSnapshot.choices, id: \.self) { Text(Self.label($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                Button { request() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel(String(localized: "Take a New Picture"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("A picture taken by the Mac: this page is served by the Mac and the phone cannot load it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .onAppear { if client.previewFiles.entry(for: pane.id, snapshot: size) == nil { request() } }
        .onChange(of: size) { if client.previewFiles.entry(for: pane.id, snapshot: size) == nil { request() } }
        .onChange(of: pane.url) { request() }
    }

    private func request() { client.requestPageSnapshot(paneID: pane.id, size: size) }

    @ViewBuilder private var content: some View {
        switch client.previewFiles.entry(for: pane.id, snapshot: size) {
        case .loaded(_, _, let data)?:
            if let image = UIImage(data: data) {
                ZoomableImage(image: image, label: String(localized: "Picture of the page, \(Int(image.size.width)) × \(Int(image.size.height)) pixels"))
                    .accessibilityIdentifier("pageSnapshot")
            } else {
                ContentUnavailableView(String(localized: "Cannot show this image"), systemImage: "photo")
            }
        case .loading?:
            ProgressView()
        case .tooLarge?:
            ContentUnavailableView(String(localized: "Too large for the phone"), systemImage: "photo")
        case .failed(let message)?:
            ContentUnavailableView(String(localized: "Could not take a picture of the page"), systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        case nil:
            if client.status.isLive { ProgressView() } else { ContentUnavailableView(client.status.label, systemImage: "wifi.slash") }
        }
    }
}
