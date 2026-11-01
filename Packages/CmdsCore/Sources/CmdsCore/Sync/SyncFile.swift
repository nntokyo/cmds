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
}

/// Sending the file of a preview pane to the phone in `file` messages (`requestFile`).
public enum SyncFile {
    /// Largest file sent. Bigger ones get one `file` message with `truncated: true` and no data.
    public static let maxBytes = 10 * 1024 * 1024
    /// Bytes per `file` message: base64 (×4/3) plus JSON stays well under `SyncCodec.maxFrameBytes`.
    public static let chunkBytes = 2 * 1024 * 1024

    /// The `file` messages for `data` (the whole file, at most `maxBytes`).
    public static func messages(paneID: String, name: String, mime: String, data: Data) -> [ServerMessage.File] {
        guard !data.isEmpty else { return [.init(paneID: paneID, name: name, mime: mime, size: 0, data: Data())] }
        var result: [ServerMessage.File] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkBytes, data.count)
            result.append(.init(paneID: paneID, name: name, mime: mime, size: data.count, offset: offset,
                                data: data.subdata(in: data.startIndex + offset ..< data.startIndex + end)))
            offset = end
        }
        return result
    }

    /// The answer for a file that is too large (or could not be read): name and type only.
    public static func truncated(paneID: String, name: String, mime: String) -> ServerMessage.File {
        .init(paneID: paneID, name: name, mime: mime, size: 0, data: Data(), truncated: true)
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

    public var hasFilesPanes: Bool { workspaces.contains { $0.panes.contains { $0.kind == .files } } }

    /// The state for phones without `SyncFeature.filesPanes`.
    public var withoutFilesPanes: ServerMessage.State {
        guard hasFilesPanes else { return self }
        var copy = self
        copy.workspaces = workspaces.map(\.withoutFilesPanes)
        return copy
    }

    public var hasPreviewPanes: Bool { workspaces.contains { $0.panes.contains { $0.kind == .preview } } }

    /// The state for phones without `SyncFeature.previewPanes`.
    public var withoutPreviewPanes: ServerMessage.State {
        guard hasPreviewPanes else { return self }
        var copy = self
        copy.workspaces = workspaces.map(\.withoutPreviewPanes)
        return copy
    }
}

extension WorkspaceInfo {
    /// For phones without `SyncFeature.filesPanes`: files panes shown as browser panes with the folder's `file://` URL.
    public var withoutFilesPanes: WorkspaceInfo {
        var copy = self
        copy.panes = panes.map { pane in
            guard pane.kind == .files else { return pane }
            var legacy = pane
            legacy.kind = .browser
            legacy.url = pane.workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true).absoluteString }
            legacy.workingDirectory = nil
            return legacy
        }
        return copy
    }

    /// For phones without `SyncFeature.previewPanes`: preview panes shown as browser panes with a `file://` URL.
    public var withoutPreviewPanes: WorkspaceInfo {
        var copy = self
        copy.panes = panes.map { pane in
            guard pane.kind == .preview else { return pane }
            var legacy = pane
            legacy.kind = .browser
            legacy.url = pane.file.map { URL(fileURLWithPath: $0).absoluteString }
            legacy.file = nil
            return legacy
        }
        return copy
    }
}
