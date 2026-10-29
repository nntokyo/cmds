import Foundation
import XCTest
@testable import CmdsCore

final class MarkdownHTMLTests: XCTestCase {
    func render(_ markdown: String) -> String { MarkdownHTML.render(markdown) }

    func testHeadingsParagraphsAndEmphasis() {
        let html = render("# Title\n\nSome **bold**, *italic*, ~~gone~~ and `code <x>`.\nNext line.\n\nSub\n---\n")
        XCTAssertTrue(html.contains("<h1 id=\"title\">Title</h1>"), html)
        XCTAssertTrue(html.contains("<p>Some <strong>bold</strong>, <em>italic</em>, <del>gone</del> and <code>code &lt;x&gt;</code>.\nNext line.</p>"), html)
        XCTAssertTrue(html.contains("<h2 id=\"sub\">Sub</h2>"), html)
    }

    func testIntrawordUnderscoreIsNotEmphasis() {
        XCTAssertEqual(render("snake_case_name and __init__"), "<p>snake_case_name and <strong>init</strong></p>\n")
    }

    func testFencedAndIndentedCode() {
        let html = render("```swift\nlet a = \"<b>\" // **no**\n```\n\n    indented\n    code\n")
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">let a = &quot;&lt;b&gt;&quot; // **no**\n</code></pre>"), html)
        XCTAssertTrue(html.contains("<pre><code>indented\ncode\n</code></pre>"), html)
    }

    func testNestedListsAndTasks() {
        let html = render("- one\n- two\n  - nested\n  - [x] done\n\npara\n\n1. a\n2. b\n")
        XCTAssertTrue(html.contains("<ul>\n<li>one</li>\n<li>two\n<ul>\n<li>nested</li>\n<li class=\"task\"><input type=\"checkbox\" disabled checked> done</li>\n</ul></li>"), html)
        XCTAssertTrue(html.contains("<ol>\n<li>a</li>\n<li>b</li>\n</ol>"), html)
    }

    func testOrderedListStart() {
        XCTAssertTrue(render("3. c\n4. d").hasPrefix("<ol start=\"3\">"))
    }

    func testTable() {
        let html = render("| a | b |\n|:--|--:|\n| 1 | `x|y` |\n")
        XCTAssertTrue(html.contains("<th style=\"text-align:left\">a</th><th style=\"text-align:right\">b</th>"), html)
        XCTAssertTrue(html.contains("<td style=\"text-align:left\">1</td><td style=\"text-align:right\"><code>x|y</code></td>"), html)
    }

    func testQuoteRuleLinksImages() {
        let html = render("> quoted\n> **text**\n\n***\n\n[site](https://example.com \"T\") ![pic](img/a.png) <https://x.org> https://y.org/a.")
        XCTAssertTrue(html.contains("<blockquote>\n<p>quoted\n<strong>text</strong></p>\n</blockquote>"), html)
        XCTAssertTrue(html.contains("<hr>"), html)
        XCTAssertTrue(html.contains("<a href=\"https://example.com\" title=\"T\">site</a>"), html)
        XCTAssertTrue(html.contains("<img src=\"img/a.png\" alt=\"pic\">"), html)
        XCTAssertTrue(html.contains("<a href=\"https://x.org\">https://x.org</a>"), html)
        XCTAssertTrue(html.contains("<a href=\"https://y.org/a\">https://y.org/a</a>."), html)
    }

    func testRawHTMLAndUnsafeLinksAreNeutralised() {
        let html = render("<script>alert(1)</script>\n\n[x](javascript:alert(1)) ![i](data:image/png;base64,AA) <img src=x onerror=y>")
        XCTAssertFalse(html.contains("<script"), html)
        XCTAssertFalse(html.contains("javascript:"), html)
        XCTAssertFalse(html.contains("<img src=x"), html)
        XCTAssertTrue(html.contains("&lt;script&gt;"), html)
    }

    func testUnclosedDelimitersStayLiteral() {
        XCTAssertEqual(render("a * b ** c ` d [e"), "<p>a * b ** c ` d [e</p>\n")
    }

    func testDeepNestingDoesNotCrash() {
        _ = render(String(repeating: "> ", count: 200) + "x")
        _ = render(String(repeating: "*", count: 5000))
        _ = render(String(repeating: "[", count: 3000))
    }
}

final class DiffHTMLTests: XCTestCase {
    func testGitDiff() {
        let diff = """
            diff --git a/src/a.swift b/src/a.swift
            index 111..222 100644
            --- a/src/a.swift
            +++ b/src/a.swift
            @@ -1,3 +1,3 @@
             keep
            -old <x>
            +new
             --- not a header
            \\ No newline at end of file

            """
        let html = DiffHTML.render(diff)
        XCTAssertTrue(html.contains("<div class=\"file-name\">src/a.swift<span class=\"stat\"><span class=\"a\">+1</span> <span class=\"d\">−1</span>"), html)
        XCTAssertTrue(html.contains("<tr class=\"del\"><td class=\"ln\">2</td><td class=\"ln\"></td><td class=\"code\">old &lt;x&gt;</td></tr>"), html)
        XCTAssertTrue(html.contains("<tr class=\"add\"><td class=\"ln\"></td><td class=\"ln\">2</td><td class=\"code\">new</td></tr>"), html)
        XCTAssertTrue(html.contains("<tr class=\"ctx\"><td class=\"ln\">3</td><td class=\"ln\">3</td><td class=\"code\">--- not a header</td></tr>"), html)
        XCTAssertEqual(html.components(separatedBy: "class=\"file\"").count, 2)
    }

    func testTwoFilesWithoutGitHeaders() {
        let diff = "--- a\n+++ b\n@@ -1 +1 @@\n-x\n+y\n--- c\n+++ d\n@@ -0,0 +1 @@\n+z\n"
        let html = DiffHTML.render(diff)
        XCTAssertEqual(html.components(separatedBy: "class=\"file\"").count, 3, html)
        XCTAssertTrue(html.contains(">d<span"), html)
    }
}

final class SyncFileTests: XCTestCase {
    func testChunksReassemble() throws {
        let data = Data((0..<(SyncFile.chunkBytes * 2 + 10)).map { UInt8($0 % 251) })
        let pieces = SyncFile.messages(paneID: "p1", name: "a.png", mime: "image/png", data: data)
        XCTAssertEqual(pieces.count, 3)
        let codec = SyncCodec()
        var assembler = SyncFileAssembler()
        var result: SyncFileAssembler.Result?
        for piece in pieces {
            let frame = try codec.encode(.file(piece))
            XCTAssertLessThan(frame.count, SyncCodec.maxFrameBytes)
            guard case .file(let decoded) = try codec.decodeServerMessage(frame) else { return XCTFail() }
            result = assembler.add(decoded)
        }
        XCTAssertEqual(result, .complete(name: "a.png", mime: "image/png", data: data))
    }

    func testEmptyAndTruncated() {
        var assembler = SyncFileAssembler()
        let empty = SyncFile.messages(paneID: "p1", name: "e.txt", mime: "text/plain", data: Data())
        XCTAssertEqual(empty.count, 1)
        XCTAssertEqual(assembler.add(empty[0]), .complete(name: "e.txt", mime: "text/plain", data: Data()))
        XCTAssertEqual(assembler.add(SyncFile.truncated(paneID: "p1", name: "big.mov", mime: "video/quicktime")),
                       .truncated(name: "big.mov", mime: "video/quicktime"))
    }

    func testOutOfOrderPieceRestarts() {
        var assembler = SyncFileAssembler()
        let piece = ServerMessage.File(paneID: "p1", name: "x", mime: "y", size: 10, offset: 5, data: Data(count: 5))
        XCTAssertEqual(assembler.add(piece), .partial(received: 0, size: 10))
    }

    func testMimeTypes() {
        XCTAssertEqual(SyncFile.mimeType(forFileName: "a.PNG"), "image/png")
        XCTAssertEqual(SyncFile.mimeType(forFileName: "r.pdf"), "application/pdf")
        XCTAssertEqual(SyncFile.mimeType(forFileName: "README.md"), "text/markdown")
        XCTAssertEqual(SyncFile.mimeType(forFileName: "x.patch"), "text/x-diff")
        XCTAssertEqual(SyncFile.mimeType(forFileName: "noext"), "application/octet-stream")
    }

    func testMessagesRoundTripAndOldPhonesStillDecodeHello() throws {
        let codec = SyncCodec()
        let request = ClientMessage.requestFile(.init(paneID: "p3"))
        XCTAssertEqual(try codec.decodeClientMessage(try codec.encode(request)), request)
        let hello = try codec.decodeClientMessage(Data(#"{"type":"hello","protocolVersion":2,"deviceName":"old"}"#.utf8))
        guard case .hello(let decoded) = hello else { return XCTFail() }
        XCTAssertNil(decoded.features)
    }

    func testLegacyStateHasNoPreviewKind() throws {
        let pane = PaneInfo(id: "p2", kind: .preview, title: "a.png", focused: false, attention: false, file: "/tmp/a b.png")
        let workspace = WorkspaceInfo(id: "w1", title: "w", selected: true, panes: [pane])
        let legacy = workspace.withoutPreviewPanes
        XCTAssertEqual(legacy.panes[0].kind, .browser)
        XCTAssertEqual(legacy.panes[0].url, "file:///tmp/a%20b.png")
        let json = String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self)
        XCTAssertFalse(json.contains("preview"), json)
    }

    func testPaneKindDecodesOldAndNewJSON() throws {
        let old = try JSONDecoder().decode(PaneInfo.self, from: Data(#"{"id":"p1","kind":"browser","title":"t","focused":true,"attention":false}"#.utf8))
        XCTAssertEqual(old.kind, .browser)
        XCTAssertNil(old.file)
        let new = try JSONDecoder().decode(PaneInfo.self, from: Data(#"{"id":"p1","kind":"preview","title":"t","focused":true,"attention":false,"file":"/x"}"#.utf8))
        XCTAssertEqual(new.kind, .preview)
        XCTAssertEqual(new.file, "/x")
    }
}

final class OpenFilePolicyTests: XCTestCase {
    func testRemoteSocketsCannotOpenFiles() {
        XCTAssertThrowsError(try RemoteAPIPolicy.authorize(method: "pane.open_file", params: ["path": "/etc/passwd"],
                                                           scope: RemoteScope(paneID: "p1", workspaceID: "w1"))) { error in
            XCTAssertEqual((error as? RPCError)?.code, 403)
            XCTAssertTrue((error as? RPCError)?.message.contains("not on this Mac") == true)
        }
    }

    func testPreviewFormat() {
        XCTAssertEqual(PreviewFormat.forFile("/a/README.MD"), .markdown)
        XCTAssertEqual(PreviewFormat.forFile("x.diff"), .diff)
        XCTAssertEqual(PreviewFormat.forFile("x.png"), .quickLook)
    }
}
