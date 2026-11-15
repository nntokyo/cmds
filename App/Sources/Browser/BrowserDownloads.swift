import AppKit
import WebKit
import CmdsCore

/// Downloads of browser panes (#235): into ~/Downloads under a name not taken yet (`BrowserDownloadName`), reported in
/// the pane's banner. WebKit quarantines the file itself (`com.apple.quarantine`, so Gatekeeper checks what is opened
/// from it). Kept here, not in the pane, so a download goes on when its pane closes.
@MainActor
final class BrowserDownloads: NSObject, WKDownloadDelegate {
    static let shared = BrowserDownloads()

    private final class Item {
        let download: WKDownload
        weak var pane: BrowserPane?
        var destination: URL?
        var name = ""

        init(download: WKDownload, pane: BrowserPane?) {
            self.download = download
            self.pane = pane
        }
    }

    private var items: [ObjectIdentifier: Item] = [:]

    func start(_ download: WKDownload, for pane: BrowserPane?) {
        download.delegate = self
        items[ObjectIdentifier(download)] = Item(download: download, pane: pane)
    }

    static var folder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        guard let item = items[ObjectIdentifier(download)] else { return completionHandler(nil) }
        let folder = Self.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = BrowserDownloadName.unique(BrowserDownloadName.sanitized(suggestedFilename), in: folder) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        item.destination = destination
        item.name = destination.lastPathComponent
        item.pane?.showNotice(.downloading(name: item.name)) { [weak self, weak download] in
            guard let download else { return }
            download.cancel { _ in }
            self?.items[ObjectIdentifier(download)] = nil
        }
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = items.removeValue(forKey: ObjectIdentifier(download)), let destination = item.destination else {
            return
        }
        // Bounces the Downloads stack in the Dock, as Safari's downloads do.
        DistributedNotificationCenter.default().post(name: Notification.Name("com.apple.DownloadFileFinished"),
                                                     object: destination.path)
        item.pane?.showNotice(.finished(name: item.name, file: destination))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = items.removeValue(forKey: ObjectIdentifier(download)) else { return }
        if (error as NSError).code == NSURLErrorCancelled {
            item.pane?.showNotice(nil)
            return
        }
        let name = item.name.isEmpty ? (download.originalRequest?.url?.lastPathComponent ?? "") : item.name
        item.pane?.showNotice(.failed(name: name, reason: error.localizedDescription))
    }
}
