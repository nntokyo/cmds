import CmdsCore
import Foundation
import Observation

/// Browsing a files pane's folders on the phone (`SyncFeature.filesBrowse`, #26 phase 4): per pane, the folders the
/// user went into (only on the phone: the Mac pane stays where it is) and the file opened from one. Listings come from
/// `requestListing` → `listing` (docs/internals/sync-protocol.md "Files panes").
@MainActor
@Observable
final class FolderBrowserStore {
    enum Listing: Equatable {
        case loading
        case loaded(entries: [SyncFileEntry], truncated: Bool)
        case failed(String)
    }

    struct Folder: Equatable {
        /// The path asked for; nil: the pane's folder (`requestListing` without a path).
        var requested: String?
        /// Absolute, once known (the requested path, or what the Mac answered for the pane's folder).
        var path: String?
        var listing: Listing = .loading

        /// Listed (failures count as not answered: they are asked for again).
        var isAnswered: Bool {
            if case .loaded = listing { return true }
            return false
        }
    }

    struct Browse: Equatable {
        /// The pane's folder first, then the folders gone into.
        var folders: [Folder]
        /// A file opened from the last folder (shown with the preview viewer).
        var file: String?
        /// The pane's folder on the Mac when this started (a new one there starts over while at the top).
        var paneFolder: String?
    }

    private(set) var browses: [String: Browse] = [:]

    func browse(for paneID: String) -> Browse? { browses[paneID] }

    /// The path to ask for the pane's own folder: its folder when it is absolute (a remote pane's may still be `~/…`).
    static func rootRequest(paneFolder: String?) -> String? {
        guard let paneFolder, paneFolder.hasPrefix("/") else { return nil }
        return RemotePath.normalized(paneFolder)
    }

    /// Starts at the pane's folder (again); returns the path to ask for.
    func start(paneID: String, paneFolder: String?) -> Folder {
        let root = Folder(requested: Self.rootRequest(paneFolder: paneFolder),
                          path: Self.rootRequest(paneFolder: paneFolder))
        browses[paneID] = Browse(folders: [root], paneFolder: paneFolder)
        return root
    }

    /// Goes into a subfolder of the folder shown; returns the path to ask for.
    func push(paneID: String, name: String) -> String? {
        guard var browse = browses[paneID], let parent = browse.folders.last?.path else { return nil }
        let path = RemotePath.normalized(RemotePath.join(parent, name))
        browse.folders.append(Folder(requested: path, path: path))
        browse.file = nil
        browses[paneID] = browse
        return path
    }

    /// Opens a file of the folder shown; returns its path.
    func open(paneID: String, name: String) -> String? {
        guard var browse = browses[paneID], let parent = browse.folders.last?.path else { return nil }
        let path = RemotePath.join(parent, name)
        browse.file = path
        browses[paneID] = browse
        return path
    }

    /// Back: closes the file, else leaves the folder. Returns the folder now shown when it has to be asked for again
    /// (its answer never came, e.g. the Mac answered a later request instead).
    func back(paneID: String) -> Folder? {
        guard var browse = browses[paneID] else { return nil }
        if browse.file != nil {
            browse.file = nil
        } else if browse.folders.count > 1 {
            browse.folders.removeLast()
        }
        browses[paneID] = browse
        guard let top = browse.folders.last, top.listing == .loading else { return nil }
        return top
    }

    /// Marks the folder shown as loading again (refresh); returns it.
    func reload(paneID: String) -> Folder? {
        guard var browse = browses[paneID], var top = browse.folders.last else { return nil }
        top.listing = .loading
        browse.folders[browse.folders.count - 1] = top
        browses[paneID] = browse
        return top
    }

    func isLoading(paneID: String) -> Bool {
        browses[paneID]?.folders.last?.listing == .loading
    }

    func receive(_ listing: ServerMessage.Listing) {
        guard var browse = browses[listing.paneID] else { return }
        let index: Int
        if let match = browse.folders.lastIndex(where: { $0.requested != nil && $0.requested == listing.path }) {
            index = match
        } else if browse.folders[0].requested == nil, browse.folders[0].listing == .loading {
            // The pane's folder, asked for without a path: the Mac says which it is.
            index = 0
        } else {
            return // a folder the user has left
        }
        var folder = browse.folders[index]
        if folder.requested == nil, !listing.path.isEmpty { folder.path = listing.path }
        if let failure = listing.failure {
            folder.listing = .failed(Self.text(failure))
        } else {
            folder.listing = .loaded(entries: listing.entries, truncated: listing.truncated == true)
        }
        browse.folders[index] = folder
        browses[listing.paneID] = browse
    }

    /// Drops the browsing of panes that are gone.
    func retain(paneIDs: Set<String>) {
        for id in browses.keys where !paneIDs.contains(id) { browses[id] = nil }
    }

    /// What the user reads for a failure.
    static func text(_ failure: SyncListing.Failure) -> String {
        switch failure {
        case .paneNotFound: return String(localized: "The pane is no longer open on the Mac.")
        case .notFilesPane: return String(localized: "This pane no longer shows a folder.")
        case .badPath: return String(localized: "This path cannot be opened.")
        case .notFound: return String(localized: "The folder or file is no longer there.")
        case .notAFolder: return String(localized: "This is not a folder.")
        case .notAFile: return String(localized: "This cannot be opened as a file.")
        case .permissionDenied: return String(localized: "Permission denied on the Mac.")
        case .remoteNotConnected:
            return String(localized: "Not available for remote folders while the pane is not connected. Open or reload the pane on the Mac.")
        case .other: return String(localized: "The folder could not be read.")
        }
    }
}
