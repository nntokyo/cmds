import Foundation
import XCTest
@testable import CmdsCore

/// Point at Element: the prompt the agent gets and the source paths it names.
final class ElementPointTests: XCTestCase {
    private func element(source: PointedElement.Source? = nil, framework: String? = nil,
                         components: [String]? = nil) -> PointedElement {
        PointedElement(tag: "button", selector: "main > form > button.primary", html: "<button class=\"primary\">",
                       text: "Save changes", rect: .init(x: 300, y: 512.4, width: 120, height: 40),
                       viewportWidth: 1280, viewportHeight: 800, scrollX: 0, scrollY: 640,
                       styles: ["font-size: 14px", "color: rgb(0, 0, 0)"], framework: framework,
                       components: components, source: source)
    }

    func testPromptPutsTheCommentFirstThenTheFacts() {
        let prompt = ElementPoint.prompt(
            comment: "  The button is too close to the field \n",
            element: element(source: .init(file: "http://localhost:5173/src/SaveButton.tsx?t=17", line: 12, column: 7, via: "stack"),
                             framework: "React", components: ["SettingsForm", "SaveButton"]),
            url: "http://localhost:5173/settings", title: "Settings", screenshot: ".cmds/reports/point-1.png")
        XCTAssertEqual(prompt, """
            The button is too close to the field

            [Pointed at in the cmds browser]
            Page: http://localhost:5173/settings ("Settings")
            Element: button "Save changes"
            Selector: main > form > button.primary
            Source: src/SaveButton.tsx:12:7 (React; line in the served module, may differ slightly)
            Components: SettingsForm › SaveButton
            Box: 120×40 at 300,512 in a 1280×800 viewport scrolled to 0,640
            Styles: font-size: 14px; color: rgb(0, 0, 0)
            HTML: <button class="primary">
            Screenshot (element outlined in red): .cmds/reports/point-1.png
            """)
    }

    func testPromptWithoutSourceOrScreenshot() {
        var plain = element(framework: "Vue")
        plain.styles = nil
        plain.scrollY = 0
        let prompt = ElementPoint.prompt(comment: "x", element: plain, url: nil, title: nil, screenshot: nil)
        XCTAssertTrue(prompt.contains("Framework: Vue"))
        XCTAssertFalse(prompt.contains("Page:"))
        XCTAssertFalse(prompt.contains("Screenshot"))
        XCTAssertFalse(prompt.contains("scrolled"))
        XCTAssertFalse(prompt.contains("Styles"))
    }

    func testSummaryPrefersTheLabelThenTextThenSelector() {
        var e = element()
        XCTAssertEqual(e.summary, "button \"Save changes\"")
        e.label = "Save"
        XCTAssertEqual(e.summary, "button \"Save\"")
        e.label = nil
        e.text = nil
        XCTAssertEqual(e.summary, "button.primary")
        e.text = String(repeating: "a", count: 60)
        XCTAssertEqual(e.summary.count, "button \"\"".count + 40)
    }

    func testSourcePaths() {
        let cases: [(String, String)] = [
            ("src/App.tsx", "src/App.tsx"),
            ("/Users/me/app/src/App.tsx", "/Users/me/app/src/App.tsx"),
            ("http://localhost:5173/src/App.tsx?t=1712", "src/App.tsx"),
            ("http://127.0.0.1:3000/src/components/Card.vue#x", "src/components/Card.vue"),
            ("http://localhost:5173/@fs/Users/me/lib/x.ts", "/Users/me/lib/x.ts"),
            ("webpack-internal:///(app-pages-browser)/./src/app/page.tsx", "src/app/page.tsx"),
            ("webpack-internal:///./src/index.js", "src/index.js"),
            ("webpack://my-app/./src/App.js", "src/App.js"),
            ("file:///Users/me/app/index.html", "/Users/me/app/index.html"),
            ("http://localhost:3000/src/My%20Page.tsx", "src/My Page.tsx"),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(ElementPoint.sourcePath(raw), expected, raw)
        }
    }

    func testMergeTakesWhatThePageFound() throws {
        var e = element()
        let info = try JSONDecoder().decode(JSONValue.self, from: Data("""
            {"framework": "Svelte", "components": ["App", "Card"],
             "source": {"file": "src/Card.svelte", "line": 4, "column": null, "via": "framework"}}
            """.utf8))
        e.merge(sourceInfo: info)
        XCTAssertEqual(e.framework, "Svelte")
        XCTAssertEqual(e.components, ["App", "Card"])
        XCTAssertEqual(e.source, .init(file: "src/Card.svelte", line: 4, column: nil, via: "framework"))
        e.merge(sourceInfo: .null)
        XCTAssertEqual(e.framework, "Svelte", "nothing found keeps what there was")
    }

    func testPickResultDecodes() throws {
        let json = """
            {"tag":"a","selector":"#home","html":"<a id=\\"home\\">","text":null,"label":"Home",
             "rect":{"x":1,"y":2,"width":3,"height":4},"viewportWidth":390,"viewportHeight":844,"scrollX":0,"scrollY":0,
             "styles":[]}
            """
        let e = try JSONDecoder().decode(PointedElement.self, from: Data(json.utf8))
        XCTAssertEqual(e.summary, "a \"Home\"")
        XCTAssertNil(e.text)
    }

    func testScreenshotName() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 15, minute: 30, second: 12))!
        XCTAssertEqual(ElementPoint.screenshotName(at: date, sequence: 3), "point-20261124-153012-3.png")
    }

    func testAgentRequest() throws {
        let plain = try ElementPoint.AgentRequest(params: nil)
        XCTAssertNil(plain.prompt)
        XCTAssertEqual(plain.timeout, ElementPoint.defaultAgentTimeout)
        let asked = try ElementPoint.AgentRequest(params: .object(["prompt": "  the gap  ", "timeout": 30]))
        XCTAssertEqual(asked.prompt, "the gap")
        XCTAssertEqual(asked.timeout, 30)
        XCTAssertNil(try ElementPoint.AgentRequest(params: .object(["prompt": "   "])).prompt)
        let long = try ElementPoint.AgentRequest(params: .object(["prompt": .string(String(repeating: "x", count: 500))]))
        XCTAssertEqual(long.prompt?.count, ElementPoint.maxAgentPromptLength)
        for bad: JSONValue in [["timeout": 0], ["timeout": 601], ["timeout": "5"], ["prompt": 3]] {
            XCTAssertThrowsError(try ElementPoint.AgentRequest(params: bad), "\(bad)")
        }
    }

    func testAgentResultHasTheFactsWithoutAComment() {
        let result = ElementPoint.agentResult(element: element(), url: "http://x.test/", title: "X")
        let text = result["text"]?.stringValue ?? ""
        XCTAssertTrue(text.hasPrefix("Page: http://x.test/ (\"X\")\nElement: button \"Save changes\""), text)
        XCTAssertFalse(text.contains("Pointed at"))
        XCTAssertEqual(result["element"]?["selector"]?.stringValue, "main > form > button.primary")
    }

    func testFrameLineComesBeforeTheElement() {
        var inFrame = element()
        inFrame.frame = "iframe#storybook-preview-iframe (http://localhost:6006/iframe.html?id=button--primary)"
        let lines = ElementPoint.facts(element: inFrame, url: "http://localhost:6006/", title: nil, screenshot: nil)
        XCTAssertEqual(Array(lines.prefix(3)), [
            "Page: http://localhost:6006/",
            "Frame: iframe#storybook-preview-iframe (http://localhost:6006/iframe.html?id=button--primary)",
            "Element: button \"Save changes\"",
        ])
        XCTAssertFalse(ElementPoint.facts(element: element(), url: nil, title: nil, screenshot: nil).contains { $0.hasPrefix("Frame:") })
    }
}
