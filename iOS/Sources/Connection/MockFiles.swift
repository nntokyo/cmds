import CmdsCore
import Foundation

/// The demo Mac's files pane (`p-files` in the report workspace) for `-mock` launches: a small made-up folder tree that
/// `MockTransport` lists for `requestListing` and whose files it sends for `requestFile` with a path, like a current Mac
/// (`SyncFeature.filesBrowse`). `-mockNoFilesBrowse` answers like a Mac before it (the pane shows its path only).
enum MockFiles {
    static let root = "/Users/demo/Source/report"
    /// Tests and screenshots: the Mac shows hidden files in that pane.
    static let showHidden = ProcessInfo.processInfo.arguments.contains("-mockShowHiddenFiles")
    private static let now = Date()

    private static func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

    /// Folders by path, with their entries (in no particular order: the listing sorts them like the Mac).
    private static let tree: [String: [FileItem]] = [
        root: [
            FileItem(name: "out", kind: .folder, modified: ago(1)),
            FileItem(name: "data", kind: .folder, modified: ago(26)),
            FileItem(name: "scripts", kind: .folder, modified: ago(240)),
            FileItem(name: "latest", kind: .symlink, modified: ago(1)),
            FileItem(name: "NOTES.md", kind: .file, size: 2_481, modified: ago(0.3)),
            FileItem(name: "README.md", kind: .file, size: 1_204, modified: ago(400)),
            FileItem(name: "report.py", kind: .file, size: 8_930, modified: ago(3)),
            FileItem(name: "requirements.txt", kind: .file, size: 96, modified: ago(700)),
            FileItem(name: ".git", kind: .folder, modified: ago(0.3)),
            FileItem(name: ".env", kind: .file, size: 64, modified: ago(700)),
        ],
        root + "/out": [
            FileItem(name: "chart.png", kind: .file, size: Int64(MockData.chartPNG().count), modified: ago(1)),
            FileItem(name: "summary.csv", kind: .file, size: 3_310, modified: ago(1)),
            FileItem(name: "build.log", kind: .file, size: 48_200, modified: ago(1)),
        ],
        root + "/data": [
            FileItem(name: "2026-10.csv", kind: .file, size: 182_400, modified: ago(26)),
            FileItem(name: "2026-11.csv", kind: .file, size: 41_022, modified: ago(2)),
            FileItem(name: "raw", kind: .folder, modified: ago(26)),
        ],
        root + "/data/raw": [],
        root + "/scripts": [
            FileItem(name: "fetch.sh", kind: .file, size: 712, modified: ago(240)),
        ],
    ]

    /// Links and where they lead.
    private static let links = [root + "/latest": root + "/out"]

    static func listing(_ request: ClientMessage.RequestListing) -> ServerMessage.Listing {
        guard request.paneID == "p-files" else {
            return .init(paneID: request.paneID, path: request.path ?? "", failure: .notFilesPane)
        }
        guard let path = try? SyncListing.path(requested: request.path, paneFolder: root) else {
            return .init(paneID: request.paneID, path: request.path ?? "", failure: .badPath)
        }
        guard let items = tree[links[path] ?? path] else {
            return .init(paneID: request.paneID, path: path, failure: .notFound)
        }
        let (entries, truncated) = SyncListing.entries(items, showHidden: showHidden, follow: { item in
            links[RemotePath.join(path, item.name)].map { FileItem(name: RemotePath.name($0), kind: .folder) }
        })
        return .init(paneID: request.paneID, path: path, entries: entries, truncated: truncated ? true : nil)
    }

    /// The `file` pieces for a file of the tree (the chart for any image), nil when there is no such file.
    static func file(paneID: String, path: String) -> [ServerMessage.File]? {
        guard paneID == "p-files", let path = try? SyncListing.path(requested: path, paneFolder: root) else { return nil }
        let name = RemotePath.name(path)
        let folder = RemotePath.parent(path)
        guard tree[links[folder] ?? folder]?.contains(where: { $0.name == name && $0.kind == .file }) == true else {
            return nil
        }
        let mime = SyncFile.mimeType(forFileName: name)
        let data = mime.hasPrefix("image/") ? MockData.chartPNG() : Data("Demo file \(name)\n".utf8)
        return SyncFile.messages(paneID: paneID, name: name, mime: mime, data: data, path: path)
    }
}
