import CmdsCore
import PDFKit
import SwiftUI
import UIKit

/// A Mac preview pane on the phone: images and PDFs are fetched (`requestFile`) and shown; other files show their
/// name and "Open on Mac".
struct PreviewFileView: View {
    @Environment(CompanionClient.self) private var client
    let pane: PaneInfo

    private var name: String {
        pane.file.map { ($0 as NSString).lastPathComponent } ?? (pane.title.isEmpty ? String(localized: "File") : pane.title)
    }
    private var mime: String { SyncFile.mimeType(forFileName: name) }
    private var viewable: Bool { PreviewFileStore.isViewable(mime: mime) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // A new file in the pane (or a reconnect) fetches again.
        .task(id: "\(pane.id)|\(pane.file ?? "")|\(client.status.isLive)") { fetchIfNeeded(force: true) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let file = pane.file {
                    Text((file as NSString).deletingLastPathComponent)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer()
            if viewable {
                Button { fetchIfNeeded(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Reload")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if !viewable {
            unavailable(String(localized: "No preview on the phone"), detail: String(localized: "\(name) is shown on the Mac."))
        } else {
            switch client.previewFiles.entry(for: pane.id) {
            case .loaded(_, let mime, let data)?:
                if mime == "application/pdf" {
                    PDFDocumentView(data: data)
                } else if let image = UIImage(data: data) {
                    ZoomableImage(image: image)
                } else {
                    unavailable(String(localized: "Cannot show this image"), detail: name)
                }
            case .loading(let received, let size)?:
                VStack(spacing: 8) {
                    if size > 0 {
                        ProgressView(value: Double(received), total: Double(size)).frame(maxWidth: 220)
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(received), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
            case .tooLarge?:
                let megabytes = SyncFile.maxBytes / 1024 / 1024
                unavailable(String(localized: "Too large for the phone"),
                            detail: String(localized: "Files over \(megabytes) MB are shown on the Mac only."))
            case .failed(let message)?:
                unavailable(String(localized: "Could not load the file"), detail: message)
            case nil:
                if client.status.isLive { ProgressView() } else { unavailable(name, detail: client.status.label) }
            }
        }
    }

    private func unavailable(_ title: String, detail: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(detail)
        } actions: {
            Button("Open on Mac") { client.focusPaneOnMac(pane.id) }
        }
    }

    private var icon: String {
        if mime.hasPrefix("image/") { return "photo" }
        if mime == "application/pdf" { return "doc.richtext" }
        if mime.hasPrefix("video/") { return "film" }
        return "doc.text"
    }

    private func fetchIfNeeded(force: Bool) {
        guard viewable, client.status.isLive else { return }
        if !force, case .loaded? = client.previewFiles.entry(for: pane.id) { return }
        client.requestFile(paneID: pane.id)
    }
}

/// Image fitted to the view; pinch to zoom, double-tap to reset.
private struct ZoomableImage: View {
    let image: UIImage
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width * zoom * pinch, height: geo.size.height * zoom * pinch)
            }
            .scrollBounceBehavior(.basedOnSize, axes: [.horizontal, .vertical])
        }
        .gesture(
            MagnifyGesture()
                .updating($pinch) { value, state, _ in state = value.magnification }
                .onEnded { value in zoom = min(8, max(1, zoom * value.magnification)) }
        )
        .onTapGesture(count: 2) { withAnimation(.snappy) { zoom = 1 } }
        .accessibilityLabel("Image")
    }
}

private struct PDFDocumentView: UIViewRepresentable {
    let data: Data

    final class Coordinator { var data: Data? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        view.document = PDFDocument(data: data)
    }
}
