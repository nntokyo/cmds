import CmdsCore
import SwiftUI

/// A Mac files pane on the phone (`SyncFeature.filesBrowse`, #26 phase 4): the folder's contents, read only. Tapping a
/// folder goes into it here only (the Mac pane stays where it is); a file opens with the preview viewer.
struct FolderBrowserView: View {
    @Environment(CompanionClient.self) private var client
    let pane: PaneInfo

    private var browse: FolderBrowserStore.Browse? { client.folders.browse(for: pane.id) }
    private var folder: FolderBrowserStore.Folder? { browse?.folders.last }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let file = browse?.file {
                let name = RemotePath.name(file)
                FilePreviewContent(name: name, entry: client.previewFiles.entry(for: pane.id, path: file),
                                   unviewableDetail: String(localized: "Images, PDFs and text files can be shown on the phone."),
                                   showsText: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        // First view, a reconnect, or a new folder in the Mac pane while at the top: list the pane's folder.
        .task(id: "\(pane.id)|\(pane.workingDirectory ?? "")|\(client.status.isLive)") { startIfNeeded() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if canGoBack {
                Button { client.browseBack(in: pane.id) } label: {
                    Image(systemName: "chevron.left").font(.body.weight(.semibold))
                }
                .accessibilityLabel("Back")
                .accessibilityIdentifier("filesBack")
            } else {
                Image(systemName: pane.remote != nil ? "network" : "folder").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer()
            Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel("Reload")
                .disabled(!client.status.isLive)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var canGoBack: Bool {
        guard let browse else { return false }
        return browse.file != nil || browse.folders.count > 1
    }

    private var shownPath: String? { browse?.file ?? folder?.path ?? pane.workingDirectory }

    private var title: String {
        guard let path = shownPath else { return pane.title }
        return RemotePath.name(path)
    }

    /// The folder (or file) path, with the host for a pane on an SSH host.
    private var subtitle: String? {
        guard let path = shownPath else { return nil }
        let shown = browse?.file != nil ? RemotePath.parent(path) : path
        guard let host = pane.remote?.host else { return shown }
        return "\(host):\(shown)"
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        switch folder?.listing {
        case .loaded(let entries, let truncated)?:
            List {
                ForEach(entries, id: \.name) { entry in
                    row(entry)
                }
                if truncated {
                    Text("Showing the first \(SyncListing.maxEntries) items. Open the folder on the Mac to see all.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView("Empty folder", systemImage: "folder")
                }
            }
            .refreshable { await client.reloadFolder(of: pane) }
            .accessibilityIdentifier("filesList")
        case .failed(let message)?:
            ScrollView {
                ContentUnavailableView {
                    Label("Cannot show this folder", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { reload() }.disabled(!client.status.isLive)
                }
                .padding(.top, 40)
            }
            .refreshable { await client.reloadFolder(of: pane) }
        case .loading?, nil:
            if client.status.isLive {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(title, systemImage: "folder", description: Text(client.status.label))
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: SyncFileEntry) -> some View {
        let content = FileEntryRow(entry: entry)
        if entry.opensAsFolder {
            Button { client.openFolder(named: entry.name, in: pane.id) } label: {
                HStack {
                    content
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .tint(.primary)
        } else if entry.kind == .file || entry.kind == .symlink {
            Button { client.openFile(named: entry.name, in: pane.id) } label: { content }
                .tint(.primary)
        } else {
            content.foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func startIfNeeded() {
        guard client.status.isLive else { return }
        guard let browse else { return client.browseFolder(of: pane) }
        let atTop = browse.folders.count == 1 && browse.file == nil
        if atTop, browse.paneFolder != pane.workingDirectory {
            client.browseFolder(of: pane)
        } else if browse.folders.last.map(\.isAnswered) == false {
            // Asked while offline, or the answer was lost with the connection.
            reload()
        } else if let file = browse.file, client.previewFiles.entry(for: pane.id, path: file) == nil {
            client.requestFile(paneID: pane.id, path: file)
        }
    }

    private func reload() {
        if let file = browse?.file {
            client.requestFile(paneID: pane.id, path: file)
        } else {
            Task { await client.reloadFolder(of: pane) }
        }
    }
}

/// One item of a folder: icon, name, size and date.
private struct FileEntryRow: View {
    let entry: SyncFileEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(entry.opensAsFolder ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                if !details.isEmpty {
                    Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        var parts: [String] = []
        if let size = entry.size, !entry.opensAsFolder {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let modified = entry.modified {
            parts.append(modified.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }

    private var icon: String {
        if entry.opensAsFolder { return "folder.fill" }
        switch entry.kind {
        case .other: return "questionmark.square.dashed"
        case .symlink where entry.size == nil: return "link"
        default: break
        }
        let mime = SyncFile.mimeType(forFileName: entry.name)
        if mime.hasPrefix("image/") { return "photo" }
        if mime == "application/pdf" { return "doc.richtext" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if PreviewFileStore.isText(name: entry.name) { return "doc.text" }
        return "doc"
    }
}
