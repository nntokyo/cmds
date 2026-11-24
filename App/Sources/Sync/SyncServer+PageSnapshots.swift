import AppKit
import CmdsCore

/// Pictures of a browser pane's page for the phone (`SyncFeature.pageSnapshots`, #174 G25): pages the phone cannot load
/// itself (this Mac's localhost) shown as the pane shows them, or at a phone, tablet or desktop size (loaded again in
/// an off-screen web view, `BrowserPane.snapshot`). Nothing on the Mac's screen changes. A paired phone can already
/// read and type into every terminal, so a picture of a page gives it nothing more.
extension SyncServer {
    /// `requestFile` with `snapshot`: one PNG in `file` pieces that repeat `snapshot`, or `error`.
    func sendPageSnapshot(paneID: String, snapshot: String, to client: Client) {
        guard client.snapshotsPages else {
            return sendError(.badRequest, "requestFile with a snapshot needs the pageSnapshots feature", to: client)
        }
        guard SyncPageSnapshot.isValid(snapshot) else { return sendError(.badRequest, "unknown snapshot size", to: client) }
        guard !client.sendingFile else { return sendError(.badRequest, "a file is already being sent", to: client) }
        client.sendingFile = true
        Task { @MainActor [weak self] in
            let result = await Result { try await AppController.shared.pageSnapshot(paneID: paneID, size: snapshot) }
            guard let self else { return }
            switch result {
            case .success(let png) where png.count <= SyncFile.maxBytes:
                let pieces = SyncFile.messages(paneID: paneID, name: SyncPageSnapshot.fileName(snapshot), mime: "image/png",
                                               data: png).map { piece -> ServerMessage.File in
                    var piece = piece
                    piece.snapshot = snapshot
                    return piece
                }
                self.sendFilePieces(pieces[...], to: client)
            case .success:
                var piece = SyncFile.truncated(paneID: paneID, name: SyncPageSnapshot.fileName(snapshot), mime: "image/png")
                piece.snapshot = snapshot
                self.sendFilePieces([piece][...], to: client)
            case .failure(let error):
                client.sendingFile = false
                self.sendError(for: error, to: client)
            }
        }
    }
}

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

extension AppController {
    /// A PNG of browser pane `paneID`'s page: as the pane shows it (`SyncPageSnapshot.asShown`; a responsive pane's
    /// frames side by side), or at a device preset's size, off screen. Also `debug.page_snapshot`.
    func pageSnapshot(paneID: String, size: String) async throws -> Data {
        let pane = try resolvePane(paneID)
        guard let browser = pane.browser else { throw RPCError.invalidParams("pane \(paneID) is not a browser pane") }
        var request = BrowserSnapshotRequest()
        if size != SyncPageSnapshot.asShown {
            guard let preset = DevicePreset.named(size) else { throw RPCError.invalidParams("unknown size \(size)") }
            request.targets = [.init(preset: preset)]
        }
        let images = try await browser.snapshot(request)
        guard let first = images.first else { throw RPCError(code: 500, message: "no picture of the page") }
        return images.count == 1 ? first.png : try Self.sideBySide(images.map(\.png))
    }

    /// The frames of a responsive pane in one PNG, left to right with a gap, tops aligned.
    private static func sideBySide(_ pngs: [Data]) throws -> Data {
        let reps = pngs.compactMap(NSBitmapImageRep.init(data:))
        let gap = 24
        let width = reps.map(\.pixelsWide).reduce(0, +) + gap * max(reps.count - 1, 0)
        let height = reps.map(\.pixelsHigh).max() ?? 0
        guard width > 0, height > 0,
              let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else {
            throw RPCError(code: 500, message: "could not combine the frames")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        NSColor(white: 0.5, alpha: 0.25).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        var x = 0
        for rep in reps {
            rep.draw(in: NSRect(x: x, y: height - rep.pixelsHigh, width: rep.pixelsWide, height: rep.pixelsHigh))
            x += rep.pixelsWide + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = canvas.representation(using: .png, properties: [:]) else {
            throw RPCError(code: 500, message: "PNG encoding failed")
        }
        return png
    }
}
