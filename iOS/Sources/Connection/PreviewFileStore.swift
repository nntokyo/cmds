import CmdsCore
import Foundation
import Observation
import UniformTypeIdentifiers

/// Files of Mac preview panes, and files opened while browsing a files pane, on the phone (`requestFile` → `file`
/// pieces, docs/internals/sync-protocol.md). One request at a time; results are kept per pane (and path, for a files
/// pane) until the pane's file changes, the pane goes away or the user reloads.
@MainActor
@Observable
final class PreviewFileStore {
    enum Entry: Equatable {
        case loading(received: Int, size: Int)
        case loaded(name: String, mime: String, data: Data)
        /// Larger than the Mac sends (`SyncFile.maxBytes`) or unreadable there.
        case tooLarge(name: String)
        case failed(String)
    }

    /// A preview pane's file (`path` nil), or a file of a files pane.
    struct Key: Hashable {
        var paneID: String
        var path: String?
    }

    private(set) var entries: [Key: Entry] = [:]
    @ObservationIgnored private var assembler = SyncFileAssembler()
    @ObservationIgnored private var pending: Key?

    /// Types the phone shows itself; others get "Open on Mac".
    static func isViewable(mime: String) -> Bool {
        mime.hasPrefix("image/") || mime == "application/pdf"
    }

    /// Plain text, source code, JSON, logs…: files of a files pane are shown as text (not preview panes, whose Mac view
    /// renders them).
    static func isText(name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if ["log", "csv", "tsv", "md", "markdown", "env", "conf", "ini", "toml", "yml", "yaml"].contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json)
            || type.conforms(to: .xml)
    }

    func entry(for paneID: String, path: String? = nil) -> Entry? { entries[Key(paneID: paneID, path: path)] }

    func begin(paneID: String, path: String? = nil) {
        let key = Key(paneID: paneID, path: path)
        assembler.reset(paneID: paneID)
        pending = key
        entries[key] = .loading(received: 0, size: 0)
    }

    func receive(_ piece: ServerMessage.File) {
        let key = Key(paneID: piece.paneID, path: piece.path)
        switch assembler.add(piece) {
        case .partial(let received, let size):
            entries[key] = .loading(received: received, size: size)
            return
        case .complete(let name, let mime, let data):
            entries[key] = .loaded(name: name, mime: mime, data: data)
        case .truncated(let name, _):
            entries[key] = .tooLarge(name: name)
        }
        if pending == key { pending = nil }
    }

    /// An `error` arrived while a request was open (older Macs answer `requestFile` with `badRequest`).
    func requestFailed(_ message: String) {
        guard let key = pending else { return }
        pending = nil
        assembler.reset(paneID: key.paneID)
        entries[key] = .failed(SyncListing.Failure(rawValue: message).map(FolderBrowserStore.text) ?? message)
    }

    /// Drops what is cached for panes that are gone.
    func retain(paneIDs: Set<String>) {
        for key in entries.keys where !paneIDs.contains(key.paneID) { entries[key] = nil }
    }

    func forget(paneID: String) {
        for key in entries.keys where key.paneID == paneID { entries[key] = nil }
        assembler.reset(paneID: paneID)
        if pending?.paneID == paneID { pending = nil }
    }
}
