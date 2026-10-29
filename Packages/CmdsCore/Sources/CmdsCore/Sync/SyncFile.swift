import Foundation
import UniformTypeIdentifiers

/// Optional protocol additions announced in `hello.features` (docs/SYNC.md).
public enum SyncFeature {
    /// The phone decodes `PaneKind.preview` and understands `requestFile` / `file`. Phones without it get preview
    /// panes as browser panes (`url` = `file://…`), because older builds fail on an unknown pane kind.
    public static let previewPanes = "preview"
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

extension WorkspaceInfo {
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
