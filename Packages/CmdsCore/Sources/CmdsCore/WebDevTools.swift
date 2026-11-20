import Foundation

// Web development tools of browser panes (docs/guide/workspaces-and-panes.md "Developer tools"): the page's source,
// and an SEO check of what the page declares (title, description, headings, canonical, robots, Open Graph, structured
// data, images, links…). The page scripts run in cmds' own content world, like the DevTools scripts
// (BrowserDevTools.swift): a page's Content Security Policy does not apply and the page cannot see them.

// MARK: - Page source

/// `browser.source`: the HTML the server sent for the page (fetched again from the page, with its cookies; the HTTP
/// cache usually answers), or with `rendered` the DOM as it is now.
public enum PageSource {
    /// At most this much source is returned (the rest is cut, `truncated`).
    public static let maxBytes = 5 * 1024 * 1024

    /// `callAsyncJavaScript` body. Argument `rendered` (Bool). Returns `{url, source, rendered, status?, contentType?}`.
    public static let script = """
        const dom = () => {
          const doctype = document.doctype ? '<!DOCTYPE ' + document.doctype.name + '>\\n' : '';
          return { url: location.href, source: doctype + document.documentElement.outerHTML, rendered: true };
        };
        if (rendered || !/^(https?|file):$/.test(location.protocol)) return dom();
        try {
          const response = await fetch(location.href, { credentials: 'include', cache: 'force-cache' });
          const source = await response.text();
          return { url: location.href, source, rendered: false, status: response.status,
                   contentType: response.headers.get('content-type') };
        } catch (e) {
          return dom();
        }
        """

    /// The source cut to `maxBytes` UTF-8 bytes at a character boundary, and whether it was cut.
    public static func capped(_ source: String, maxBytes: Int = maxBytes) -> (source: String, truncated: Bool) {
        guard source.utf8.count > maxBytes else { return (source, false) }
        var end = source.utf8.index(source.utf8.startIndex, offsetBy: maxBytes)
        while end > source.startIndex, !source.unicodeScalars.indices.contains(end) {
            end = source.utf8.index(before: end)
        }
        return (String(source[..<end]), true)
    }
}

/// The source view of a preview pane (`PreviewFormat.source`): line numbers and light HTML colouring (tags,
/// attributes, strings, comments, doctype). Not a parser: it colours what looks like markup, line by line.
public enum SourceHTML {
    public static func page(_ source: String, title: String) -> String {
        PreviewHTML.page(title: title, bodyClass: "source", body: render(source), extraCSS: css)
    }

    public static func render(_ source: String) -> String {
        var rows: [String] = []
        var inComment = false
        var number = 0
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            number += 1
            let (html, stillInComment) = colour(String(line.hasSuffix("\r") ? line.dropLast() : line), inComment: inComment)
            inComment = stillInComment
            rows.append("<tr><td class=\"ln\">\(number)</td><td class=\"code\">\(html)</td></tr>")
        }
        return "<table class=\"source\">" + rows.joined() + "</table>"
    }

    /// One line with spans; `inComment`: the line starts inside `<!-- … -->`.
    static func colour(_ line: String, inComment: Bool) -> (String, Bool) {
        var out = ""
        var rest = Substring(line)
        var inComment = inComment
        while !rest.isEmpty {
            if inComment {
                if let end = rest.range(of: "-->") {
                    out += span("c", rest[..<end.upperBound])
                    rest = rest[end.upperBound...]
                    inComment = false
                } else {
                    out += span("c", rest)
                    rest = ""
                }
                continue
            }
            guard let open = rest.firstIndex(of: "<") else {
                out += PreviewHTML.escape(String(rest))
                break
            }
            out += PreviewHTML.escape(String(rest[..<open]))
            rest = rest[open...]
            if rest.hasPrefix("<!--") {
                inComment = true
                continue
            }
            // A tag up to its `>` on this line (attributes on later lines stay plain).
            let close = rest.firstIndex(of: ">").map { rest.index(after: $0) } ?? rest.endIndex
            out += tag(rest[..<close])
            rest = rest[close...]
        }
        return (out, inComment)
    }

    private static func tag(_ text: Substring) -> String {
        if text.hasPrefix("<!") { return span("d", text) }
        // `<name` or `</name`, then attributes.
        var index = text.index(after: text.startIndex)
        if index < text.endIndex, text[index] == "/" { index = text.index(after: index) }
        let nameEnd = text[index...].firstIndex { $0 == " " || $0 == ">" || $0 == "/" || $0 == "\t" } ?? text.endIndex
        var out = span("p", text[..<index]) + span("t", text[index..<nameEnd])
        var rest = text[nameEnd...]
        while !rest.isEmpty {
            let character = rest.first!
            if character == "\"" || character == "'" {
                let after = rest.index(after: rest.startIndex)
                let end = rest[after...].firstIndex(of: character).map { rest.index(after: $0) } ?? rest.endIndex
                out += span("s", rest[..<end])
                rest = rest[end...]
            } else if character.isLetter || character == "-" || character == ":" || character == "@" {
                let end = rest.firstIndex { !($0.isLetter || $0.isNumber || "-_:.@".contains($0)) } ?? rest.endIndex
                out += span("a", rest[..<end])
                rest = rest[end...]
            } else {
                let end = rest.index(after: rest.startIndex)
                out += "=/>".contains(character) ? span("p", rest[..<end]) : PreviewHTML.escape(String(rest[..<end]))
                rest = rest[end...]
            }
        }
        return out
    }

    private static func span(_ kind: String, _ text: Substring) -> String {
        "<span class=\"\(kind)\">" + PreviewHTML.escape(String(text)) + "</span>"
    }

    static let css = """
        body.source { padding: 0; }
        table.source { display: table; width: 100%; margin: 0; border: 0; border-collapse: collapse;
          font: 12px/1.5 ui-monospace, "SF Mono", Menlo, monospace; }
        table.source td { border: 0; padding: 0 10px; background: none; vertical-align: top; }
        table.source tr:nth-child(2n) td { background: none; }
        table.source td.ln { width: 1%; min-width: 4ch; text-align: right; color: var(--muted); user-select: none;
          white-space: nowrap; border-right: 1px solid var(--border); }
        table.source td.code { white-space: pre-wrap; word-break: break-all; }
        .source .t { color: #116329; } .source .a { color: #0550ae; } .source .s { color: #0a3069; }
        .source .c { color: var(--muted); font-style: italic; } .source .d { color: #8250df; } .source .p { color: var(--muted); }
        @media (prefers-color-scheme: dark) { .source .t { color: #7ee787; } .source .a { color: #79c0ff; }
          .source .s { color: #a5d6ff; } .source .d { color: #d2a8ff; } }
        """
}

// MARK: - SEO

/// What the page declares, collected by `SEOAudit.script` in the page.
public struct PageFacts: Codable, Equatable, Sendable {
    public struct Heading: Codable, Equatable, Sendable {
        public var level: Int
        public var text: String

        public init(level: Int, text: String) {
            self.level = level
            self.text = text
        }
    }

    public struct RobotsTxt: Codable, Equatable, Sendable {
        /// HTTP status of `/robots.txt` (0: not fetched).
        public var status: Int
        /// `Disallow: /` for every user agent (`User-agent: *`).
        public var disallowsAll: Bool
        /// `Sitemap:` lines.
        public var sitemaps: Int

        public init(status: Int, disallowsAll: Bool = false, sitemaps: Int = 0) {
            self.status = status
            self.disallowsAll = disallowsAll
            self.sitemaps = sitemaps
        }
    }

    public var url: String
    public var title: String?
    public var description: String?
    public var canonical: String?
    /// `<meta name="robots">` (and `googlebot`) contents, lowercased.
    public var robots: String?
    public var lang: String?
    public var viewport: String?
    public var charset: String?
    public var headings: [Heading]
    public var openGraph: [String: String]
    public var twitterCard: String?
    public var images: Int
    public var imagesWithoutAlt: Int
    /// A few `src` of images without `alt`.
    public var imagesWithoutAltExamples: [String]
    public var links: Int
    public var internalLinks: Int
    public var externalLinks: Int
    public var nofollowLinks: Int
    /// Links with no text, no `aria-label`/`title` and no image with `alt`.
    public var emptyLinks: Int
    /// `@type`s of the JSON-LD blocks.
    public var structuredDataTypes: [String]
    /// JSON-LD blocks that are not valid JSON.
    public var structuredDataErrors: Int
    public var hreflang: Int
    public var favicon: Bool
    public var wordCount: Int
    /// The navigation's HTTP status when WebKit reports it.
    public var status: Int?
    /// `http:` resources on an `https:` page.
    public var mixedContent: Int
    public var robotsTxt: RobotsTxt?

    public init(url: String, title: String? = nil, description: String? = nil, canonical: String? = nil,
                robots: String? = nil, lang: String? = nil, viewport: String? = nil, charset: String? = nil,
                headings: [Heading] = [], openGraph: [String: String] = [:], twitterCard: String? = nil,
                images: Int = 0, imagesWithoutAlt: Int = 0, imagesWithoutAltExamples: [String] = [], links: Int = 0,
                internalLinks: Int = 0, externalLinks: Int = 0, nofollowLinks: Int = 0, emptyLinks: Int = 0,
                structuredDataTypes: [String] = [], structuredDataErrors: Int = 0, hreflang: Int = 0,
                favicon: Bool = false, wordCount: Int = 0, status: Int? = nil, mixedContent: Int = 0,
                robotsTxt: RobotsTxt? = nil) {
        self.url = url
        self.title = title
        self.description = description
        self.canonical = canonical
        self.robots = robots
        self.lang = lang
        self.viewport = viewport
        self.charset = charset
        self.headings = headings
        self.openGraph = openGraph
        self.twitterCard = twitterCard
        self.images = images
        self.imagesWithoutAlt = imagesWithoutAlt
        self.imagesWithoutAltExamples = imagesWithoutAltExamples
        self.links = links
        self.internalLinks = internalLinks
        self.externalLinks = externalLinks
        self.nofollowLinks = nofollowLinks
        self.emptyLinks = emptyLinks
        self.structuredDataTypes = structuredDataTypes
        self.structuredDataErrors = structuredDataErrors
        self.hreflang = hreflang
        self.favicon = favicon
        self.wordCount = wordCount
        self.status = status
        self.mixedContent = mixedContent
        self.robotsTxt = robotsTxt
    }
}

/// One finding of the SEO check.
public struct SEOCheck: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable, Comparable {
        case fail, warn, info, pass

        var rank: Int {
            switch self {
            case .fail: 0
            case .warn: 1
            case .info: 2
            case .pass: 3
            }
        }

        public static func < (lhs: Status, rhs: Status) -> Bool { lhs.rank < rhs.rank }

        /// `✗` `!` `i` `✓`.
        public var mark: String {
            switch self {
            case .fail: "✗"
            case .warn: "!"
            case .info: "i"
            case .pass: "✓"
            }
        }
    }

    /// Stable id (`title`, `description`, `h1`…).
    public var id: String
    public var status: Status
    public var message: String

    public init(_ id: String, _ status: Status, _ message: String) {
        self.id = id
        self.status = status
        self.message = message
    }
}

/// `browser.seo`: the checks, worst first, and a score (100 less 15 per failure and 5 per warning).
public struct SEOReport: Codable, Equatable, Sendable {
    public var url: String
    public var score: Int
    public var checks: [SEOCheck]
    public var facts: PageFacts

    public init(facts: PageFacts) {
        url = facts.url
        checks = SEOAudit.checks(facts).enumerated().sorted { lhs, rhs in
            lhs.element.status == rhs.element.status ? lhs.offset < rhs.offset : lhs.element.status < rhs.element.status
        }.map(\.element)
        let failures = checks.filter { $0.status == .fail }.count
        let warnings = checks.filter { $0.status == .warn }.count
        score = max(0, 100 - failures * 15 - warnings * 5)
        self.facts = facts
    }

    /// Plain text for the CLI and MCP: the score line, then one line per check.
    public var text: String {
        (["SEO \(score)/100  \(url)"] + checks.map { "\($0.status.mark) \($0.id): \($0.message)" }).joined(separator: "\n")
    }

    /// The report shown in a preview pane.
    public var markdown: String {
        var lines = ["# SEO report", "", "**\(score)/100** · \(markdownEscaped(url))", ""]
        let groups: [(SEOCheck.Status, String)] = [(.fail, "Problems"), (.warn, "Warnings"), (.info, "Notes"), (.pass, "Passed")]
        for (status, heading) in groups {
            let found = checks.filter { $0.status == status }
            guard !found.isEmpty else { continue }
            lines += ["## \(heading)", ""] + found.map { "- **\($0.id)** — \(markdownEscaped($0.message))" } + [""]
        }
        lines += ["## Page", "", "| | |", "|---|---|"]
        let og = ["title", "description", "image", "url", "type"].compactMap { key in
            facts.openGraph[key].map { "og:\(key) = \($0)" }
        }
        let rows: [(String, String?)] = [
            ("Title", facts.title), ("Description", facts.description), ("Canonical", facts.canonical),
            ("Robots", facts.robots), ("Language", facts.lang), ("Viewport", facts.viewport),
            ("Open Graph", og.isEmpty ? nil : og.joined(separator: "<br>")),
            ("Twitter card", facts.twitterCard),
            ("Structured data", facts.structuredDataTypes.isEmpty ? nil : facts.structuredDataTypes.joined(separator: ", ")),
            ("Links", "\(facts.links) (\(facts.internalLinks) internal, \(facts.externalLinks) external, \(facts.nofollowLinks) nofollow)"),
            ("Images", "\(facts.images) (\(facts.imagesWithoutAlt) without alt)"),
            ("Words", String(facts.wordCount)),
        ]
        for (name, value) in rows {
            lines.append("| \(name) | \(value.map { tableCell($0) } ?? "—") |")
        }
        if !facts.headings.isEmpty {
            lines += ["", "## Headings", ""]
            lines += facts.headings.prefix(SEOAudit.maxHeadings).map {
                String(repeating: "  ", count: max(0, $0.level - 1)) + "- h\($0.level) \(markdownEscaped($0.text))"
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func markdownEscaped(_ text: String) -> String {
        var out = ""
        for character in text {
            if "\\`*_[]<>|#".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    private func tableCell(_ text: String) -> String {
        // `<br>` joins Open Graph lines; everything else is escaped.
        text.components(separatedBy: "<br>").map(markdownEscaped).joined(separator: "<br>")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

public enum SEOAudit {
    /// In display width (`displayWidth`): what search results show before cutting, about 60 Latin or 30 Japanese
    /// characters for a title.
    public static let titleRange = 10...60
    public static let descriptionRange = 50...160

    /// Characters with wide (CJK, full-width) ones counting 2, as search results measure titles.
    public static func displayWidth(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { width, scalar in
            let v = scalar.value
            let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
                || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
                || (0xFFE0...0xFFE6).contains(v)
            return width + (wide ? 2 : 1)
        }
    }
    public static let thinContentWords = 300
    /// Headings collected and listed.
    public static let maxHeadings = 60

    /// The checks for `facts`, in a fixed order (`SEOReport` sorts them).
    public static func checks(_ facts: PageFacts) -> [SEOCheck] {
        var checks: [SEOCheck] = []
        func add(_ id: String, _ status: SEOCheck.Status, _ message: String) { checks.append(SEOCheck(id, status, message)) }
        let url = URL(string: facts.url)
        let host = url?.host?.lowercased() ?? ""
        let local = host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1"
            || url?.scheme == "file"

        if let status = facts.status, status >= 400 {
            add("status", .fail, "the page answered HTTP \(status)")
        }

        let title = facts.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty {
            add("title", .fail, "no <title>")
        } else if !titleRange.contains(displayWidth(title)) {
            add("title", .warn, "\(title.count) characters, width \(displayWidth(title)) (aim for \(titleRange.lowerBound)–\(titleRange.upperBound); wide characters count 2): \(title)")
        } else {
            add("title", .pass, "\(title.count) characters: \(title)")
        }

        let description = facts.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if description.isEmpty {
            add("description", .warn, "no <meta name=\"description\">")
        } else if !descriptionRange.contains(displayWidth(description)) {
            add("description", .warn, "\(description.count) characters, width \(displayWidth(description)) (aim for \(descriptionRange.lowerBound)–\(descriptionRange.upperBound); wide characters count 2)")
        } else {
            add("description", .pass, "\(description.count) characters")
        }

        let h1 = facts.headings.filter { $0.level == 1 }
        switch h1.count {
        case 0: add("h1", .fail, "no <h1>")
        case 1: add("h1", .pass, "one <h1>: \(h1[0].text)")
        default: add("h1", .warn, "\(h1.count) <h1> headings (one is usual)")
        }
        var previous = 0
        var skips: [String] = []
        for heading in facts.headings {
            if previous > 0, heading.level > previous + 1 { skips.append("h\(previous) → h\(heading.level)") }
            previous = heading.level
        }
        if !skips.isEmpty {
            add("headings", .warn, "heading levels skipped: " + skips.prefix(5).joined(separator: ", "))
        } else if !facts.headings.isEmpty {
            add("headings", .pass, "\(facts.headings.count) headings in order")
        }

        let robots = facts.robots ?? ""
        if robots.contains("noindex") || robots.contains("none") {
            add("robots", .fail, "<meta name=\"robots\"> asks search engines not to index the page (\(robots))")
        } else if robots.contains("nofollow") {
            add("robots", .warn, "<meta name=\"robots\"> asks not to follow the links (\(robots))")
        } else {
            add("robots", .pass, robots.isEmpty ? "indexable (no robots meta tag)" : "indexable (\(robots))")
        }
        if let txt = facts.robotsTxt, txt.status != 0 {
            if txt.status == 200, txt.disallowsAll {
                add("robots.txt", .fail, "robots.txt disallows the whole site for every crawler")
            } else if txt.status == 200 {
                add("robots.txt", txt.sitemaps > 0 ? .pass : .info,
                    txt.sitemaps > 0 ? "robots.txt names \(txt.sitemaps) sitemap\(txt.sitemaps == 1 ? "" : "s")"
                        : "robots.txt has no Sitemap: line")
            } else if txt.status == 404 {
                add("robots.txt", .info, "no robots.txt (everything may be crawled)")
            }
        }

        if let canonical = facts.canonical?.trimmingCharacters(in: .whitespaces), !canonical.isEmpty {
            let target = URL(string: canonical, relativeTo: url)?.absoluteURL
            if target?.host?.lowercased() != host, target?.host != nil {
                add("canonical", .info, "points to another host: \(canonical)")
            } else {
                add("canonical", .pass, canonical)
            }
        } else {
            add("canonical", .warn, "no <link rel=\"canonical\">")
        }

        if (facts.lang ?? "").isEmpty { add("lang", .warn, "no lang attribute on <html>") } else { add("lang", .pass, facts.lang!) }
        if (facts.viewport ?? "").isEmpty {
            add("viewport", .fail, "no <meta name=\"viewport\"> (the page is not set up for phones)")
        } else {
            add("viewport", .pass, facts.viewport!)
        }

        let ogMissing = ["title", "description", "image"].filter { (facts.openGraph[$0] ?? "").isEmpty }
        if ogMissing.isEmpty {
            add("open-graph", .pass, "og:title, og:description and og:image set")
        } else {
            add("open-graph", .warn, "missing " + ogMissing.map { "og:\($0)" }.joined(separator: ", ") + " (link previews)")
        }
        if (facts.twitterCard ?? "").isEmpty { add("twitter-card", .info, "no twitter:card") }

        if facts.imagesWithoutAlt > 0 {
            let examples = facts.imagesWithoutAltExamples.prefix(3).joined(separator: ", ")
            add("alt", .warn, "\(facts.imagesWithoutAlt) of \(facts.images) images without alt" + (examples.isEmpty ? "" : ": \(examples)"))
        } else if facts.images > 0 {
            add("alt", .pass, "all \(facts.images) images have alt")
        }
        if facts.emptyLinks > 0 { add("links", .warn, "\(facts.emptyLinks) links without text or label") }

        if facts.structuredDataErrors > 0 {
            add("structured-data", .warn, "\(facts.structuredDataErrors) JSON-LD block\(facts.structuredDataErrors == 1 ? " is" : "s are") not valid JSON")
        } else if facts.structuredDataTypes.isEmpty {
            add("structured-data", .info, "no JSON-LD structured data")
        } else {
            add("structured-data", .pass, facts.structuredDataTypes.joined(separator: ", "))
        }

        if url?.scheme == "http", !local {
            add("https", .warn, "served over http, not https")
        } else if facts.mixedContent > 0 {
            add("https", .warn, "\(facts.mixedContent) http: resources on an https page")
        } else if url?.scheme == "https" {
            add("https", .pass, "https")
        }
        if facts.wordCount < thinContentWords {
            add("content", .info, "\(facts.wordCount) words of text (thin pages rank poorly)")
        }
        if !facts.favicon { add("favicon", .info, "no <link rel=\"icon\">") }
        if (facts.charset ?? "").isEmpty { add("charset", .info, "no <meta charset>") }
        return checks
    }

    /// `callAsyncJavaScript` body: returns `PageFacts` as JSON. Fetches `/robots.txt` of http(s) pages (same origin).
    public static let script = """
        const meta = (selector) => { const el = document.querySelector(selector); return el ? (el.getAttribute('content') || '').trim() : null; };
        const text = (el) => (el.innerText || el.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 200);
        const headings = [...document.querySelectorAll('h1,h2,h3,h4,h5,h6')].slice(0, \(maxHeadings))
          .map(h => ({ level: Number(h.tagName[1]), text: text(h) }));
        const og = {};
        for (const el of document.querySelectorAll('meta[property^="og:"]')) {
          const key = el.getAttribute('property').slice(3);
          if (!(key in og)) og[key] = (el.getAttribute('content') || '').trim();
        }
        const images = [...document.images];
        const noAlt = images.filter(img => !img.hasAttribute('alt'));
        const links = [...document.querySelectorAll('a[href]')];
        let internal = 0, external = 0, nofollow = 0, empty = 0;
        for (const a of links) {
          try { (new URL(a.href, location.href)).host === location.host ? internal++ : external++; } catch (e) {}
          if ((a.getAttribute('rel') || '').toLowerCase().includes('nofollow')) nofollow++;
          const label = (a.innerText || '').trim() || a.getAttribute('aria-label') || a.getAttribute('title')
            || [...a.querySelectorAll('img[alt]')].map(i => i.alt).join('');
          if (!label) empty++;
        }
        const types = []; let ldErrors = 0;
        const addTypes = (node) => {
          if (Array.isArray(node)) { node.forEach(addTypes); return; }
          if (!node || typeof node !== 'object') return;
          const t = node['@type'];
          if (t) (Array.isArray(t) ? t : [t]).forEach(x => { if (typeof x === 'string' && !types.includes(x)) types.push(x); });
          if (node['@graph']) addTypes(node['@graph']);
        };
        for (const s of document.querySelectorAll('script[type="application/ld+json"]')) {
          try { addTypes(JSON.parse(s.textContent)); } catch (e) { ldErrors++; }
        }
        const robots = [meta('meta[name="robots" i]'), meta('meta[name="googlebot" i]')].filter(Boolean).join(', ').toLowerCase();
        const canonical = document.querySelector('link[rel="canonical" i]');
        const charset = document.querySelector('meta[charset]');
        let mixed = 0;
        if (location.protocol === 'https:') {
          for (const el of document.querySelectorAll('img[src],script[src],link[href],iframe[src],video[src],audio[src],source[src]')) {
            const v = el.getAttribute('src') || el.getAttribute('href') || '';
            if (/^http:/i.test(v) && !(el.tagName === 'LINK' && /canonical|alternate/i.test(el.rel))) mixed++;
          }
        }
        let status = null;
        try { const nav = performance.getEntriesByType('navigation')[0]; if (nav && nav.responseStatus) status = nav.responseStatus; } catch (e) {}
        let robotsTxt = null;
        if (/^https?:$/.test(location.protocol)) {
          try {
            const r = await fetch(location.origin + '/robots.txt', { credentials: 'omit', redirect: 'follow' });
            const body = r.ok ? (await r.text()).slice(0, 200000) : '';
            let agentAll = false, disallowsAll = false, sitemaps = 0;
            for (const raw of body.split(/\\r?\\n/)) {
              const line = raw.replace(/#.*/, '').trim();
              const m = line.match(/^([A-Za-z-]+)\\s*:\\s*(.*)$/); if (!m) continue;
              const key = m[1].toLowerCase(), value = m[2].trim();
              if (key === 'user-agent') agentAll = value === '*';
              else if (key === 'disallow' && agentAll && value === '/') disallowsAll = true;
              else if (key === 'sitemap') sitemaps++;
            }
            robotsTxt = { status: r.status, disallowsAll, sitemaps };
          } catch (e) { robotsTxt = { status: 0, disallowsAll: false, sitemaps: 0 }; }
        }
        // Japanese, Chinese and Korean have no spaces: two of their characters count as a word.
        const bodyText = document.body ? document.body.innerText : '';
        const cjk = (bodyText.match(/[\\u3040-\\u30ff\\u3400-\\u9fff\\uf900-\\ufaff\\uac00-\\ud7af]/g) || []).length;
        const words = bodyText.replace(/[\\u3040-\\u30ff\\u3400-\\u9fff\\uf900-\\ufaff\\uac00-\\ud7af]/g, ' ')
          .split(/\\s+/).filter(Boolean).length + Math.round(cjk / 2);
        return {
          url: location.href, title: document.title || null, description: meta('meta[name="description" i]'),
          canonical: canonical ? canonical.getAttribute('href') : null, robots: robots || null,
          lang: document.documentElement.getAttribute('lang'), viewport: meta('meta[name="viewport" i]'),
          charset: charset ? charset.getAttribute('charset') : null, headings, openGraph: og,
          twitterCard: meta('meta[name="twitter:card" i]'), images: images.length, imagesWithoutAlt: noAlt.length,
          imagesWithoutAltExamples: noAlt.slice(0, 5).map(i => (i.currentSrc || i.src || '').slice(0, 200)),
          links: links.length, internalLinks: internal, externalLinks: external, nofollowLinks: nofollow, emptyLinks: empty,
          structuredDataTypes: types.slice(0, 30), structuredDataErrors: ldErrors,
          hreflang: document.querySelectorAll('link[rel="alternate" i][hreflang]').length,
          favicon: !!document.querySelector('link[rel~="icon" i]'), wordCount: words, status, mixedContent: mixed, robotsTxt
        };
        """
}
