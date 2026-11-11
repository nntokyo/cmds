import XCTest
@testable import CmdsCore

final class BrowserWindowsTests: XCTestCase {
    private let page = URL(string: "https://example.com/next")!

    // MARK: - New windows

    func testBlankLinksOpenANewPane() {
        XCTAssertEqual(BrowserNewWindow.decide(isLinkActivation: true, hasWindowFeatures: false, url: page,
                                               paneOnScreen: true, canOpenPane: true), .newPane(page))
        // Also from a pane in a hidden workspace (an agent's click): a pane, never a window.
        XCTAssertEqual(BrowserNewWindow.decide(isLinkActivation: true, hasWindowFeatures: false, url: page,
                                               paneOnScreen: false, canOpenPane: true), .newPane(page))
        XCTAssertEqual(BrowserNewWindow.decide(isLinkActivation: true, hasWindowFeatures: false, url: page,
                                               paneOnScreen: true, canOpenPane: false), .samePane(page))
        let file = URL(fileURLWithPath: "/tmp/a.html")
        XCTAssertEqual(BrowserNewWindow.decide(isLinkActivation: true, hasWindowFeatures: false, url: file,
                                               paneOnScreen: true, canOpenPane: true), .newPane(file))
    }

    func testScriptsAndFeaturesGetAPopup() {
        // window.open with a size: a sign-in pop-up.
        XCTAssertEqual(BrowserNewWindow.decide(isLinkActivation: false, hasWindowFeatures: true, url: page,
                                               paneOnScreen: true, canOpenPane: true), .popup)
        // window.open without features keeps its opener too.
        XCTAssertEqual(BrowserNewWindow.decide(isLinkActivation: false, hasWindowFeatures: false, url: page,
                                               paneOnScreen: true, canOpenPane: true), .popup)
        // A link with features (rare) or to a page the script fills itself.
        XCTAssertEqual(BrowserNewWindow.decide(isLinkActivation: true, hasWindowFeatures: true, url: page,
                                               paneOnScreen: true, canOpenPane: true), .popup)
        XCTAssertEqual(BrowserNewWindow.decide(isLinkActivation: true, hasWindowFeatures: false,
                                               url: URL(string: "about:blank"), paneOnScreen: true, canOpenPane: true),
                       .popup)
        XCTAssertEqual(BrowserNewWindow.decide(isLinkActivation: false, hasWindowFeatures: false, url: nil,
                                               paneOnScreen: true, canOpenPane: true), .popup)
    }

    func testNoWindowsFromPanesOffScreen() {
        XCTAssertEqual(BrowserNewWindow.decide(isLinkActivation: false, hasWindowFeatures: true, url: page,
                                               paneOnScreen: false, canOpenPane: true), .refuse)
        XCTAssertEqual(BrowserNewWindow.decide(isLinkActivation: false, hasWindowFeatures: false, url: nil,
                                               paneOnScreen: false, canOpenPane: true), .refuse)
    }

    // MARK: - Pop-up size

    func testPopupSize() {
        let screen = CGSize(width: 1440, height: 900)
        XCTAssertEqual(BrowserPopupSize.clamped(width: nil, height: nil, available: screen), BrowserPopupSize.defaultSize)
        XCTAssertEqual(BrowserPopupSize.clamped(width: 600, height: 700, available: screen), CGSize(width: 600, height: 700))
        XCTAssertEqual(BrowserPopupSize.clamped(width: 10, height: 20, available: screen), BrowserPopupSize.minimum)
        XCTAssertEqual(BrowserPopupSize.clamped(width: 5000, height: 5000, available: screen), CGSize(width: 1400, height: 860))
        XCTAssertEqual(BrowserPopupSize.clamped(width: 5000, height: 5000, available: CGSize(width: 3000, height: 2000)),
                       BrowserPopupSize.maximum)
        XCTAssertEqual(BrowserPopupSize.clamped(width: -1, height: .nan, available: screen), BrowserPopupSize.defaultSize)
        XCTAssertEqual(BrowserPopupSize.clamped(width: 450.4, height: nil, available: screen).width, 450)
        // A screen smaller than the minimum wins over the minimum.
        XCTAssertEqual(BrowserPopupSize.clamped(width: 100, height: 100, available: CGSize(width: 300, height: 200)),
                       CGSize(width: 260, height: 160))
    }

    // MARK: - Download names

    func testSanitizedNames() {
        XCTAssertEqual(BrowserDownloadName.sanitized("report.pdf"), "report.pdf")
        XCTAssertEqual(BrowserDownloadName.sanitized("../../etc/passwd"), "passwd")
        XCTAssertEqual(BrowserDownloadName.sanitized(".zshrc"), "zshrc")
        XCTAssertEqual(BrowserDownloadName.sanitized("a:b\u{7}c.txt"), "a_b_c.txt")
        XCTAssertEqual(BrowserDownloadName.sanitized("  見積書.xlsx "), "見積書.xlsx")
        XCTAssertEqual(BrowserDownloadName.sanitized(nil), "download")
        XCTAssertEqual(BrowserDownloadName.sanitized(" / "), "download")
        XCTAssertEqual(BrowserDownloadName.sanitized("..."), "download")
        let long = BrowserDownloadName.sanitized(String(repeating: "あ", count: 100) + ".tar.gz")
        XCTAssertLessThanOrEqual(long.utf8.count, 200)
        XCTAssertTrue(long.hasSuffix("あ.tar.gz"))
    }

    func testUniqueNames() {
        let folder = URL(fileURLWithPath: "/Users/me/Downloads")
        var taken: Set<String> = []
        func next(_ name: String) -> String {
            let url = BrowserDownloadName.unique(name, in: folder) { taken.contains($0.lastPathComponent) }
            XCTAssertEqual(url.deletingLastPathComponent().path, folder.path)
            taken.insert(url.lastPathComponent)
            return url.lastPathComponent
        }
        XCTAssertEqual(next("report.pdf"), "report.pdf")
        XCTAssertEqual(next("report.pdf"), "report 2.pdf")
        XCTAssertEqual(next("report.pdf"), "report 3.pdf")
        XCTAssertEqual(next("archive.tar.gz"), "archive.tar.gz")
        XCTAssertEqual(next("archive.tar.gz"), "archive 2.tar.gz")
        XCTAssertEqual(next("README"), "README")
        XCTAssertEqual(next("README"), "README 2")
        XCTAssertEqual(next("v1.2.zip"), "v1.2.zip")
        XCTAssertEqual(next("v1.2.zip"), "v1.2 2.zip")
    }

    func testAttachments() {
        XCTAssertTrue(BrowserDownloadName.isAttachment(contentDisposition: "attachment"))
        XCTAssertTrue(BrowserDownloadName.isAttachment(contentDisposition: "Attachment; filename=\"a.txt\""))
        XCTAssertTrue(BrowserDownloadName.isAttachment(contentDisposition: " attachment ;filename=a"))
        XCTAssertFalse(BrowserDownloadName.isAttachment(contentDisposition: "inline; filename=\"a.pdf\""))
        XCTAssertFalse(BrowserDownloadName.isAttachment(contentDisposition: "attachments"))
        XCTAssertFalse(BrowserDownloadName.isAttachment(contentDisposition: nil))
    }

    // MARK: - Dialogs

    func testDialogOrigin() {
        XCTAssertEqual(BrowserDialogOrigin.label(scheme: "https", host: "example.com", port: 0), "example.com")
        XCTAssertEqual(BrowserDialogOrigin.label(scheme: "https", host: "example.com", port: 443), "example.com")
        XCTAssertEqual(BrowserDialogOrigin.label(scheme: "http", host: "127.0.0.1", port: 8000), "127.0.0.1:8000")
        XCTAssertEqual(BrowserDialogOrigin.label(scheme: "HTTP", host: "::1", port: 3000), "[::1]:3000")
        XCTAssertNil(BrowserDialogOrigin.label(scheme: "file", host: "", port: 0))
        XCTAssertNil(BrowserDialogOrigin.label(scheme: "about", host: "", port: 0))
    }
}
