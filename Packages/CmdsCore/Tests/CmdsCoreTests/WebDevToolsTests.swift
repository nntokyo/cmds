import XCTest
@testable import CmdsCore

final class WebDevToolsTests: XCTestCase {
    private func good() -> PageFacts {
        PageFacts(url: "https://example.com/page", title: "A good page title about things",
                  description: String(repeating: "Describes the page well. ", count: 4), canonical: "https://example.com/page",
                  lang: "en", viewport: "width=device-width, initial-scale=1", charset: "utf-8",
                  headings: [.init(level: 1, text: "Main"), .init(level: 2, text: "Part"), .init(level: 3, text: "Detail")],
                  openGraph: ["title": "T", "description": "D", "image": "https://example.com/i.png"], twitterCard: "summary",
                  images: 3, links: 10, internalLinks: 8, externalLinks: 2, structuredDataTypes: ["Article"],
                  favicon: true, wordCount: 800, status: 200, robotsTxt: .init(status: 200, sitemaps: 1))
    }

    func testAGoodPageScoresFull() {
        let report = SEOReport(facts: good())
        XCTAssertEqual(report.score, 100, report.text)
        XCTAssertTrue(report.checks.allSatisfy { $0.status == .pass }, report.text)
    }

    func testProblemsAndWarnings() {
        var facts = good()
        facts.title = nil
        facts.description = "short"
        facts.headings = [.init(level: 1, text: "A"), .init(level: 1, text: "B"), .init(level: 4, text: "C")]
        facts.robots = "noindex, nofollow"
        facts.viewport = nil
        facts.imagesWithoutAlt = 2
        facts.imagesWithoutAltExamples = ["https://example.com/a.png"]
        facts.openGraph = [:]
        facts.structuredDataErrors = 1
        facts.robotsTxt = .init(status: 200, disallowsAll: true)
        facts.status = 404
        let report = SEOReport(facts: facts)
        let byID = Dictionary(report.checks.map { ($0.id, $0.status) }) { first, _ in first }
        XCTAssertEqual(byID["status"], .fail)
        XCTAssertEqual(byID["title"], .fail)
        XCTAssertEqual(byID["description"], .warn)
        XCTAssertEqual(byID["h1"], .warn)
        XCTAssertEqual(byID["headings"], .warn)
        XCTAssertEqual(byID["robots"], .fail)
        XCTAssertEqual(byID["robots.txt"], .fail)
        XCTAssertEqual(byID["viewport"], .fail)
        XCTAssertEqual(byID["alt"], .warn)
        XCTAssertEqual(byID["open-graph"], .warn)
        XCTAssertEqual(byID["structured-data"], .warn)
        XCTAssertEqual(report.checks.first?.status, .fail, "worst first")
        XCTAssertEqual(report.score, 0, "never below zero")
        XCTAssertTrue(report.text.contains("✗ title: no <title>"))
        XCTAssertTrue(report.markdown.contains("## Problems"))
        XCTAssertTrue(report.markdown.contains("\\<title\\>"), "markdown is escaped")
    }

    func testLocalPagesAreNotAskedForHTTPS() {
        var facts = good()
        facts.url = "http://localhost:5173/"
        facts.canonical = "http://localhost:5173/"
        XCTAssertFalse(SEOReport(facts: facts).checks.contains { $0.id == "https" && $0.status == .warn })
        facts.url = "http://example.com/"
        XCTAssertTrue(SEOReport(facts: facts).checks.contains { $0.id == "https" && $0.status == .warn })
    }

    func testFactsDecodeFromThePageScriptShape() throws {
        let json = """
        {"url":"https://e.test/","title":"T","description":null,"canonical":null,"robots":null,"lang":"ja","viewport":null,
         "charset":"utf-8","headings":[{"level":1,"text":"H"}],"openGraph":{"title":"x"},"twitterCard":null,"images":1,
         "imagesWithoutAlt":0,"imagesWithoutAltExamples":[],"links":2,"internalLinks":1,"externalLinks":1,"nofollowLinks":0,
         "emptyLinks":0,"structuredDataTypes":[],"structuredDataErrors":0,"hreflang":0,"favicon":true,"wordCount":12,
         "status":null,"mixedContent":0,"robotsTxt":{"status":404,"disallowsAll":false,"sitemaps":0}}
        """
        let facts = try JSONDecoder().decode(PageFacts.self, from: Data(json.utf8))
        XCTAssertEqual(facts.lang, "ja")
        XCTAssertEqual(facts.robotsTxt?.status, 404)
        XCTAssertTrue(SEOReport(facts: facts).checks.contains { $0.id == "robots.txt" && $0.status == .info })
    }

    func testWideCharactersCountDouble() {
        XCTAssertEqual(SEOAudit.displayWidth("abc"), 3)
        XCTAssertEqual(SEOAudit.displayWidth("テスト"), 6)
        var facts = good()
        facts.title = "日本語のページタイトル"  // 11 characters, width 22
        XCTAssertEqual(SEOReport(facts: facts).checks.first { $0.id == "title" }?.status, .pass)
        facts.title = String(repeating: "長", count: 35)  // width 70
        XCTAssertEqual(SEOReport(facts: facts).checks.first { $0.id == "title" }?.status, .warn)
    }

    func testSourceIsCutAtACharacterBoundary() {
        let text = String(repeating: "あ", count: 10)  // 3 bytes each
        let capped = PageSource.capped(text, maxBytes: 10)
        XCTAssertTrue(capped.truncated)
        XCTAssertEqual(capped.source, "あああ")
        XCTAssertFalse(PageSource.capped("abc", maxBytes: 10).truncated)
    }

    func testSourceHTMLColoursMarkupAndEscapes() {
        let html = SourceHTML.render("<!DOCTYPE html>\n<a href=\"x\">Hi & bye</a>\n<!-- one\ntwo -->")
        XCTAssertTrue(html.contains("<td class=\"ln\">4</td>"))
        XCTAssertTrue(html.contains("<span class=\"d\">&lt;!DOCTYPE html&gt;</span>"), html)
        XCTAssertTrue(html.contains("<span class=\"t\">a</span>"), html)
        XCTAssertTrue(html.contains("<span class=\"a\">href</span>"), html)
        XCTAssertTrue(html.contains("<span class=\"s\">&quot;x&quot;</span>") || html.contains("<span class=\"s\">\"x\"</span>"), html)
        XCTAssertTrue(html.contains("Hi &amp; bye"), html)
        XCTAssertTrue(html.contains("<span class=\"c\">two --&gt;</span>"), "a comment goes on across lines: \(html)")
        XCTAssertFalse(html.contains("<a href"), "no live markup")
    }
}
