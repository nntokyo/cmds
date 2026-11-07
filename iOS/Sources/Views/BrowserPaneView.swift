import CmdsCore
import SwiftUI

/// A Mac browser pane on the phone: the same page in a web view, loaded by the phone itself (its own network and
/// cookies, not the Mac's). Pages served by the Mac (localhost) cannot be reached from the phone.
struct BrowserPaneView: View {
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
