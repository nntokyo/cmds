import CmdsCore
import Foundation
import Observation

/// Files of Mac preview panes on the phone (`requestFile` → `file` pieces, docs/SYNC.md). One request at a time;
/// results are kept per pane and file path until the pane's file changes or the user reloads.
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

    private(set) var entries: [String: Entry] = [:]
    @ObservationIgnored private var assembler = SyncFileAssembler()
    @ObservationIgnored private var pendingPaneID: String?

    /// Types the phone shows itself; others get "Open on Mac".
    static func isViewable(mime: String) -> Bool {
        mime.hasPrefix("image/") || mime == "application/pdf"
    }

    func entry(for paneID: String) -> Entry? { entries[paneID] }

    func begin(paneID: String) {
        assembler.reset(paneID: paneID)
        pendingPaneID = paneID
        entries[paneID] = .loading(received: 0, size: 0)
    }

    func receive(_ piece: ServerMessage.File) {
        switch assembler.add(piece) {
        case .partial(let received, let size):
            entries[piece.paneID] = .loading(received: received, size: size)
            return
        case .complete(let name, let mime, let data):
            entries[piece.paneID] = .loaded(name: name, mime: mime, data: data)
        case .truncated(let name, _):
            entries[piece.paneID] = .tooLarge(name: name)
        }
        if pendingPaneID == piece.paneID { pendingPaneID = nil }
    }

    /// An `error` arrived while a request was open (older Macs answer `requestFile` with `badRequest`).
    func requestFailed(_ message: String) {
        guard let paneID = pendingPaneID else { return }
        pendingPaneID = nil
        assembler.reset(paneID: paneID)
        entries[paneID] = .failed(message)
    }

    /// Drops what is cached for panes that are gone.
    func retain(paneIDs: Set<String>) {
        for id in entries.keys where !paneIDs.contains(id) { entries[id] = nil }
    }

    func forget(paneID: String) {
        entries[paneID] = nil
        assembler.reset(paneID: paneID)
        if pendingPaneID == paneID { pendingPaneID = nil }
    }
}
