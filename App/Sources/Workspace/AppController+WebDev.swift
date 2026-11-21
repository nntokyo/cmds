import AppKit
import CryptoKit
import CmdsCore

/// Web development tools (docs/guide/workspaces-and-panes.md "Developer tools"): the page source and the SEO report of
/// a browser pane, each written to a file in the support folder and shown in a preview tab beside the pane.
extension AppController {
    /// `<support>/Developer`: page sources and SEO reports shown in preview tabs (overwritten per page).
    static var developerFolder: URL { CmdsEnv.supportDirectoryURL().appendingPathComponent("Developer", isDirectory: true) }

    /// `source-example.com-3f2a9c1b.html`: what it is (the tab's title starts with it), the host and a hash of the URL,
    /// so each page has its file.
    static func developerFileName(_ kind: String, for url: String, extension ext: String) -> String {
        let host = URL(string: url)?.host ?? "page"
        let safe = String(host.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "-" }.prefix(60))
        let digest = SHA256.hash(data: Data(url.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(kind)-\(safe.isEmpty ? "page" : safe)-\(digest).\(ext)"
    }

    /// Writes `text` into the developer folder (0600) and shows it in a preview tab beside `browserPaneID`, or in the
    /// preview tab already showing that file. Returns the preview pane.
    @discardableResult
    func showDeveloperFile(_ text: String, name: String, format: PreviewFormat, besideBrowser browserPaneID: String,
                           focus: Bool = true) throws -> PaneInfo {
        let folder = Self.developerFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let browser = try resolvePane(browserPaneID)
        let target = PreviewTarget(path: file.path, format: format)
        if let workspace = workspace(id: browser.workspaceID),
           let existing = workspace.orderedPanes.first(where: { $0.preview?.path == file.path }) {
            existing.preview?.open(path: file.path, format: format)
            if focus {
                try focusPane(id: existing.id)
            } else if let leaf = workspace.root?.leaf(for: existing.id), leaf.paneID != existing.id,
                      !(workspace.focusedPaneID.map(leaf.tabs.contains) ?? false) {
                // Shown, unless that hides the pane with the keyboard.
                leaf.selectTab(existing.id)
                emit(.workspace(id: workspace.id))
            }
            return try paneInfo(id: existing.id)
        }
        return try split(paneID: browser.id, direction: .right, kind: .preview, focus: focus, file: target,
                         asTab: AppSettings.shared.browserOpensTabs)
    }

    /// View › Developer › View Page Source (⌥⌘U).
    func showPageSource(paneID: String, rendered: Bool = false) async throws {
        let source = try await readyBrowser(paneID: paneID).pageSource(rendered: rendered)
        let name = Self.developerFileName(rendered ? "dom" : "source", for: source.url, extension: "html")
        try showDeveloperFile((source.notCached ? PageSource.notCachedNote : "") + source.source, name: name, format: .source,
                              besideBrowser: paneID)
    }

    /// View › Developer › SEO Report.
    func showSEOReport(paneID: String) async throws {
        let report = try await readyBrowser(paneID: paneID).seoReport()
        let name = Self.developerFileName("seo", for: report.url, extension: "md")
        try showDeveloperFile(SEOReport(facts: report.facts, text: .localized).markdown, name: name, format: .markdown,
                              besideBrowser: paneID)
    }

    /// The developer menu of a browser pane, or a menu command: beeps when the page gave nothing.
    func runDeveloperAction(_ action: BrowserDeveloperAction, paneID: String) {
        Task { @MainActor in
            do {
                switch action {
                case .source: try await showPageSource(paneID: paneID)
                case .seo: try await showSEOReport(paneID: paneID)
                }
            } catch {
                NSSound.beep()
                NSLog("cmds: developer tool failed: \(error)")
            }
        }
    }
}
