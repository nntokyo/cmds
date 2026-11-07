import CmdsCore
import Foundation

/// Browsing files panes from the phone, read only (docs/internals/sync-protocol.md "Files panes", #26 phase 4): phones
/// that list `SyncFeature.filesBrowse` ask for a folder of a files pane (`requestListing` → `listing`) or one of its
/// files (`requestFile` with `path` → `file` pieces, as for preview panes). Reads happen off the main thread through
/// `SyncFolderReader` (CmdsCore). A remote pane is read only through the SFTP connection the pane already has open;
/// a phone never makes cmds connect to a host. Nothing here writes, renames or deletes, and the Mac pane stays where it
/// is.
extension SyncServer {
    /// `requestListing`: one read at a time per phone; a request that comes meanwhile waits, the latest replacing an
    /// earlier waiting one (the phone moved on). Every request is answered with `listing`, failures in its `error`.
    func sendListing(_ request: ClientMessage.RequestListing, to client: Client) {
        guard client.browsesFiles else {
            return sendError(.badRequest, "requestListing needs the filesBrowse feature", to: client)
        }
        guard !client.readingListing else {
            client.pendingListing = request
            return
        }
        let pane: (location: FileLocation, showHidden: Bool)
        do {
            pane = try AppController.shared.filesPaneFolder(paneID: request.paneID)
        } catch {
            return send(.listing(.init(paneID: request.paneID, path: request.path ?? "", failure: Self.paneFailure(error))),
                        to: client)
        }
        client.readingListing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let listing = Self.listing(request, location: pane.location, showHidden: pane.showHidden)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    client.readingListing = false
                    guard let self, !client.closing, self.clients[client.connection.id] === client else { return }
                    self.send(.listing(listing), to: client)
                    if let next = client.pendingListing {
                        client.pendingListing = nil
                        self.sendListing(next, to: client)
                    }
                }
            }
        }
    }

    /// `requestFile` with a path: that file of a files pane in `file` pieces (at most `SyncFile.maxBytes`, else one
    /// `truncated` piece), or `error` (`notFound`; `badRequest` with a `SyncListing.Failure` as the message).
    func sendBrowsedFile(paneID: String, path: String, to client: Client) {
        guard client.browsesFiles else {
            return sendError(.badRequest, "requestFile with a path needs the filesBrowse feature", to: client)
        }
        guard !client.sendingFile else { return sendError(.badRequest, "a file is already being sent", to: client) }
        let pane: (location: FileLocation, showHidden: Bool)
        do {
            pane = try AppController.shared.filesPaneFolder(paneID: paneID)
        } catch {
            return sendError(for: error, to: client)
        }
        client.sendingFile = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                let reader = try Self.reader(for: pane.location)
                return try reader.file(paneID: paneID, path: reader.path(requested: path, paneFolder: pane.location.path))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return client.sendingFile = false }
                    switch result {
                    case .success(let pieces):
                        self.sendFilePieces(pieces[...], to: client)
                    case .failure(let error):
                        client.sendingFile = false
                        let failure = SyncListing.failure(for: error)
                        self.sendError(failure == .notFound ? .notFound : .badRequest, failure.rawValue, to: client)
                    }
                }
            }
        }
    }

    /// Why `filesPaneFolder` refused a pane: gone (`RPCError.notFound`), else not a files pane.
    private nonisolated static func paneFailure(_ error: Error) -> SyncListing.Failure {
        (error as? RPCError)?.code == RPCError.notFound("").code ? .paneNotFound : .notFilesPane
    }

    /// The `listing` for a request. Blocks (file system, SFTP); never on the main thread.
    private nonisolated static func listing(_ request: ClientMessage.RequestListing, location: FileLocation,
                                            showHidden: Bool) -> ServerMessage.Listing {
        do {
            let reader = try reader(for: location)
            let path = try reader.path(requested: request.path, paneFolder: location.path)
            return reader.listing(paneID: request.paneID, path: path, showHidden: showHidden)
        } catch {
            return .init(paneID: request.paneID, path: request.path ?? location.path,
                         failure: SyncListing.failure(for: error))
        }
    }

    /// This Mac's files, or the host's through its open connection (`remoteNotConnected` when it has none).
    private nonisolated static func reader(for location: FileLocation) throws -> SyncFolderReader {
        guard let host = location.host else { return .local() }
        guard let tree = RemoteConnections.shared.openTree(host: host) else {
            throw SyncListing.ListingError(.remoteNotConnected)
        }
        return .server(tree)
    }
}
