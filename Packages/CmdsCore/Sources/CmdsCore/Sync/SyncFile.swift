import Foundation
import UniformTypeIdentifiers

/// Optional protocol additions (docs/internals/sync-protocol.md): the phone lists what it understands in
/// `hello.features`, the Mac what it answers in `welcome.features`.
public enum SyncFeature {
    /// Phone: decodes `PaneKind.preview` and understands `requestFile` / `file`. Phones without it get preview
    /// panes as browser panes (`url` = `file://…`), because older builds fail on an unknown pane kind.
    public static let previewPanes = "preview"
    /// Mac: answers `requestScrollback` with `scrollback` (the rows above a pane's screen).
    public static let scrollback = "scrollback"
    /// Phone (`hello.features`) and Mac (`welcome.features`): after the Mac answered a pane's `requestScrollback`,
    /// its `screen` / `screenDiff` to that phone carry the rows that left the top of the screen since the previous
    /// one (`scrolledOff`), or `historyReset` when the rows above the screen no longer continue what was sent.
    public static let scrollbackStream = "scrollbackStream"
    /// Phone: decodes `PaneKind.files`. Phones without it get files panes as browser panes (`url` = the folder's
    /// `file://` URL), like preview panes before `previewPanes`.
    public static let filesPanes = "files"
    /// Phone (`hello.features`) and Mac (`welcome.features`): `screen` carries `styles` and `screenDiff` rows carry
    /// `runs`, the colours and attributes of the rows (`StyleRun`). Phones without it get plain text only.
    public static let styles = "styles"
    /// Phone (`hello.features`) and Mac (`welcome.features`): the Mac sends `schedules`, a read-only summary of its
    /// schedules and their recent runs (#45 phase 3), after `welcome` and on change. Phones without it never get it.
    public static let schedules = "schedules"
    /// Phone (`hello.features`) and Mac (`welcome.features`): the phone browses a files pane's folders, read only
    /// (`requestListing` → `listing`, `requestFile` with `path` → `file`, #26 phase 4; SyncListing.swift). Phones
    /// without it never send these; with a Mac without it the phone shows the folder's path only.
    public static let filesBrowse = "filesBrowse"
}

/// Sending the file of a preview pane to the phone in `file` messages (`requestFile`).
public enum SyncFile {
    /// Largest file sent. Bigger ones get one `file` message with `truncated: true` and no data.
    public static let maxBytes = 10 * 1024 * 1024
    /// Bytes per `file` message: base64 (×4/3) plus JSON stays well under `SyncCodec.maxFrameBytes`.
    public static let chunkBytes = 2 * 1024 * 1024

    /// The `file` messages for `data` (the whole file, at most `maxBytes`). `path`: the file of a files pane that was
    /// asked for (`requestFile.path`), repeated in every piece.
    public static func messages(paneID: String, name: String, mime: String, data: Data,
                                path: String? = nil) -> [ServerMessage.File] {
        guard !data.isEmpty else {
            return [.init(paneID: paneID, name: name, mime: mime, size: 0, data: Data(), path: path)]
        }
        var result: [ServerMessage.File] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkBytes, data.count)
            result.append(.init(paneID: paneID, name: name, mime: mime, size: data.count, offset: offset,
                                data: data.subdata(in: data.startIndex + offset ..< data.startIndex + end), path: path))
            offset = end
        }
        return result
    }

    /// The answer for a file that is too large (or could not be read): name and type only.
    public static func truncated(paneID: String, name: String, mime: String, path: String? = nil) -> ServerMessage.File {
        .init(paneID: paneID, name: name, mime: mime, size: 0, data: Data(), truncated: true, path: path)
    }

    /// MIME type from the file name (`application/octet-stream` when unknown).
    public static func mimeType(forFileName name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "markdown", "mdown", "mkd": return "text/markdown"
        case "diff", "patch": return "text/x-diff"
        case "": return "application/octet-stream"
        default: return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}

/// Phone side: joins the `file` pieces of one pane. Pieces out of order or of another size restart it.
public struct SyncFileAssembler: Sendable {
    public enum Result: Equatable, Sendable {
        /// More pieces to come (`received` of `size` bytes).
        case partial(received: Int, size: Int)
        case complete(name: String, mime: String, data: Data)
        /// The Mac did not send the content (too large / unreadable).
        case truncated(name: String, mime: String)
    }

    private var buffers: [String: (size: Int, data: Data)] = [:]

    public init() {}

    public mutating func add(_ piece: ServerMessage.File) -> Result {
        if piece.truncated == true {
            buffers[piece.paneID] = nil
            return .truncated(name: piece.name, mime: piece.mime)
        }
        var buffer = buffers[piece.paneID] ?? (piece.size, Data())
        if piece.offset == 0 || buffer.size != piece.size || buffer.data.count != piece.offset {
            buffer = (piece.size, Data())
            guard piece.offset == 0 else {
                buffers[piece.paneID] = nil
                return .partial(received: 0, size: piece.size)
            }
        }
        buffer.data.append(piece.data)
        guard buffer.data.count < piece.size else {
            buffers[piece.paneID] = nil
            return .complete(name: piece.name, mime: piece.mime, data: buffer.data.prefix(piece.size))
        }
        buffers[piece.paneID] = buffer
        return .partial(received: buffer.data.count, size: piece.size)
    }

    public mutating func reset(paneID: String) { buffers[paneID] = nil }
}

extension ServerMessage.State {
    /// The state for a phone with these `hello.features`: pane kinds it cannot decode become browser panes.
    public func forPhone(supportsPreview: Bool, supportsFiles: Bool) -> ServerMessage.State {
        var state = self
        if !supportsFiles { state = state.withoutFilesPanes }
        if !supportsPreview { state = state.withoutPreviewPanes }
        return state
    }

    public var hasFilesPanes: Bool { hasPanes(.files) }

    /// The state for phones without `SyncFeature.filesPanes`.
    public var withoutFilesPanes: ServerMessage.State {
        hasFilesPanes ? mapWorkspaces(\.withoutFilesPanes) : self
    }

    public var hasPreviewPanes: Bool { hasPanes(.preview) }

    /// The state for phones without `SyncFeature.previewPanes`.
    public var withoutPreviewPanes: ServerMessage.State {
        hasPreviewPanes ? mapWorkspaces(\.withoutPreviewPanes) : self
    }

    private func hasPanes(_ kind: PaneKind) -> Bool { workspaces.contains { $0.panes.contains { $0.kind == kind } } }

    private func mapWorkspaces(_ transform: (WorkspaceInfo) -> WorkspaceInfo) -> ServerMessage.State {
        var copy = self
        copy.workspaces = workspaces.map(transform)
        return copy
    }
}

extension WorkspaceInfo {
    /// For phones without `SyncFeature.filesPanes`: files panes shown as browser panes with the folder's `file://` URL.
    public var withoutFilesPanes: WorkspaceInfo {
        asBrowserPanes(.files) { pane in
            // A folder on an SSH host has no file:// URL on the phone.
            pane.url = pane.remote != nil ? nil
                : pane.workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true).absoluteString }
            pane.workingDirectory = nil
        }
    }

    /// For phones without `SyncFeature.previewPanes`: preview panes shown as browser panes with a `file://` URL.
    public var withoutPreviewPanes: WorkspaceInfo {
        asBrowserPanes(.preview) { pane in
            pane.url = pane.file.map { URL(fileURLWithPath: $0).absoluteString }
            pane.file = nil
        }
    }

    /// Panes of `kind` turned into browser panes; `legacy` moves what they show into the browser fields.
    private func asBrowserPanes(_ kind: PaneKind, _ legacy: (inout PaneInfo) -> Void) -> WorkspaceInfo {
        var copy = self
        copy.panes = panes.map { pane in
            guard pane.kind == kind else { return pane }
            var browser = pane
            browser.kind = .browser
            legacy(&browser)
            return browser
        }
        return copy
    }
}
