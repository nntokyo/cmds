import XCTest
@testable import CmdsCore

final class FileOpeningTests: XCTestCase {
    func testDocumentsOpenInAPane() {
        for path in ["/a/photo.JPG", "/a/report.pdf", "/a/README.md", "/a/main.swift", "/a/data.xlsx", "/a/Makefile",
                     "/a/.zshrc", "/a/page.html"] {
            XCTAssertTrue(FileOpening.opensInPane(path), path)
        }
    }

    func testImagesInstallersAndArchivesOpenInTheirApp() {
        for path in ["/a/cmds-0.41.0.dmg", "/a/Setup.pkg", "/a/src.zip", "/a/logs.tar.gz", "/a/run.command",
                     "/a/Site.webloc"] {
            XCTAssertFalse(FileOpening.opensInPane(path), path)
        }
    }
}
