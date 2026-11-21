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

    /// `callAsyncJavaScript` body. Arguments `rendered` (Bool), `fetchAgain` (Bool: ask the server when the page is not
    /// in the cache), `maxBytes` (Int). Returns `{url, source, rendered, notCached?, status?, contentType?}`.

    /// The first line of a source view: what was shown (`url`, HTTP status, content type, encoding), as an HTML comment
    /// (`--` in the values is broken up so the comment cannot end early).
    public static func headerLine(url: String, status: Int?, contentType: String?, charset: String?, rendered: Bool) -> String {
        let parts = [url, status.map { "HTTP \($0)" }, contentType, charset.map { "decoded as \($0)" },
                     rendered ? "DOM after scripts" : "from the cache"].compactMap { $0 }
        var text = parts.joined(separator: " · ")
        while text.contains("--") { text = text.replacingOccurrences(of: "--", with: "- -") }
        if text.hasSuffix("-") { text += " " }
        return "<!-- cmds: " + text + " -->\n"
    }

    /// The first line of a source view that shows the DOM because the HTML was not in the cache.
    public static let notCachedNote = "<!-- cmds: the HTML of this page is not in the cache, so this is the DOM after scripts ran. `cmds browser source --fetch` asks the server again (a GET, which may repeat what the URL does). -->\n"
    public static let script = """
        const dom = (notCached) => {
          const doctype = document.doctype ? '<!DOCTYPE ' + document.doctype.name + '>\\n' : '';
          return { url: location.href, source: doctype + document.documentElement.outerHTML, rendered: true, notCached: !!notCached };
        };
        // Pages that are no HTML (images, video, PDF in the pane): their DOM.
        if (rendered || !/^(https?|file):$/.test(location.protocol) || !/html|xml/i.test(document.contentType || '')) return dom();
        try {
          // From the cache; only with `fetch` asked again (a GET with the page's cookies, which may repeat what the URL
          // does). Not in the cache: the DOM, marked `notCached`.
          let response;
          try { response = await fetch(location.href, { credentials: 'include', cache: 'only-if-cached', mode: 'same-origin' }); }
          catch (e) {
            if (!fetchAgain) return dom(true);
            response = await fetch(location.href, { credentials: 'include', cache: 'force-cache' });
          }
          // Some engines answer an uncached `only-if-cached` with a made-up 504 instead of failing.
          if (response.status === 504) {
            if (!fetchAgain) return dom(true);
            response = await fetch(location.href, { credentials: 'include', cache: 'force-cache' });
          }
          // Read at most maxBytes (+1 to tell it was cut), decoded with the page's own encoding (Shift_JIS, EUC-JP…).
          const reader = response.body.getReader();
          const chunks = []; let size = 0;
          while (size <= maxBytes) {
            const { done, value } = await reader.read();
            if (done) break;
            chunks.push(value); size += value.length;
          }
          try { reader.cancel(); } catch (e) {}
          const bytes = new Uint8Array(Math.min(size, maxBytes + 1)); let offset = 0;
          for (const chunk of chunks) { const part = chunk.subarray(0, bytes.length - offset); bytes.set(part, offset); offset += part.length; if (offset >= bytes.length) break; }
          let decoder;
          try { decoder = new TextDecoder(document.characterSet || 'utf-8'); } catch (e) { decoder = new TextDecoder('utf-8'); }
          return { url: location.href, source: decoder.decode(bytes), rendered: false, status: response.status,
                   contentType: response.headers.get('content-type'), charset: document.characterSet };
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

    /// Above this size the lines are not coloured (it takes seconds and much memory on the main thread).
    public static let colourLimit = 1_000_000

    public static func render(_ source: String) -> String {
        var rows: [String] = []
        var inComment = false
        var number = 0
        let colours = source.utf8.count <= colourLimit
        // By UTF-16 units: "\r\n" is one Character to Swift and would not split at "\n".
        for raw in source.components(separatedBy: "\n") {
            number += 1
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let (html, stillInComment) = colours ? colour(line, inComment: inComment) : (PreviewHTML.escape(line), false)
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
        /// The `Disallow:` paths of the `*` group (at most 200): the crawl (`SEOAudit.crawlScript`) skips them…
        public var disallowed: [String]?
        /// …unless an `Allow:` path of the group matches longer.
        public var allowed: [String]?

        public init(status: Int, disallowsAll: Bool = false, sitemaps: Int = 0, disallowed: [String]? = nil,
                    allowed: [String]? = nil) {
            self.status = status
            self.disallowsAll = disallowsAll
            self.sitemaps = sitemaps
            self.disallowed = disallowed
            self.allowed = allowed
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
    /// Loading measures (`PerformanceObserver`, navigation and resource timing); nil fields: not reported by WebKit.
    public var vitals: Vitals?
    /// With `hreflang` alternates: whether one of them is this page.
    public var hreflangSelf: Bool?
    /// The first sitemap robots.txt names (on the page's own site): its status and whether it lists this page.
    public var sitemap: SitemapCheck?

    public struct Vitals: Codable, Equatable, Sendable {
        /// Largest Contentful Paint, First Contentful Paint, time to first byte (ms); Cumulative Layout Shift.
        public var lcp: Double?
        public var fcp: Double?
        public var ttfb: Double?
        public var cls: Double?
        /// Bytes transferred for the page and its resources (cross-site resources without timing headers count 0).
        public var transferBytes: Int?
        public var domNodes: Int?

        public init(lcp: Double? = nil, fcp: Double? = nil, ttfb: Double? = nil, cls: Double? = nil,
                    transferBytes: Int? = nil, domNodes: Int? = nil) {
            self.lcp = lcp
            self.fcp = fcp
            self.ttfb = ttfb
            self.cls = cls
            self.transferBytes = transferBytes
            self.domNodes = domNodes
        }
    }

    public struct SitemapCheck: Codable, Equatable, Sendable {
        public var url: String
        public var status: Int
        public var listsPage: Bool

        public init(url: String, status: Int, listsPage: Bool) {
            self.url = url
            self.status = status
            self.listsPage = listsPage
        }
    }

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

/// One page of the crawl (`browser.seo` with `crawl`): what its HTML declares, without running it.
public struct CrawlPage: Codable, Equatable, Sendable {
    public var url: String
    /// HTTP status (0: no answer, a timeout, or not HTML).
    public var status: Int
    public var title: String?
    public var description: String?
    public var h1: Int
    public var canonical: String?
    public var noindex: Bool

    public init(url: String, status: Int, title: String? = nil, description: String? = nil, h1: Int = 0,
                canonical: String? = nil, noindex: Bool = false) {
        self.url = url
        self.status = status
        self.title = title
        self.description = description
        self.h1 = h1
        self.canonical = canonical
        self.noindex = noindex
    }
}

/// `browser.seo`: the checks, worst first, and a score (100 less 15 per failure and 5 per warning).
public struct SEOReport: Codable, Equatable, Sendable {
    public var url: String
    public var score: Int
    public var checks: [SEOCheck]
    public var facts: PageFacts
    /// The crawl's pages (`crawl`), the page itself not included; nil without a crawl.
    public var pages: [CrawlPage]?

    /// The labels of `markdown` (English unless the app passes its own).
    private var words: SEOText = .english

    private enum CodingKeys: String, CodingKey { case url, score, checks, facts, pages }

    public static func == (lhs: SEOReport, rhs: SEOReport) -> Bool {
        lhs.url == rhs.url && lhs.score == rhs.score && lhs.checks == rhs.checks && lhs.facts == rhs.facts
            && lhs.pages == rhs.pages
    }

    /// `text`: the language of the messages and of `markdown` (the API and CLI keep English). `pages`: a crawl of the
    /// site's linked pages, checked together with this one.
    public init(facts: PageFacts, pages: [CrawlPage]? = nil, text: SEOText = .english) {
        words = text
        url = facts.url
        self.pages = pages
        checks = (SEOAudit.checks(facts, text: text) + SEOAudit.crawlChecks(page: facts, pages: pages, text: text))
            .enumerated().sorted { lhs, rhs in
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
        let label = words.label
        var lines = ["# \(label(.report))", "", "**\(score)/100** · \(code(url))", ""]
        let groups: [(SEOCheck.Status, String)] = [(.fail, label(.problems)), (.warn, label(.warnings)), (.info, label(.notes)),
                                                   (.pass, label(.passed))]
        for (status, heading) in groups {
            let found = checks.filter { $0.status == status }
            guard !found.isEmpty else { continue }
            lines += ["## \(heading)", ""] + found.map { "- **\($0.id)** — \(markdownEscaped($0.message))" } + [""]
        }
        lines += ["## \(label(.page))", "", "| | |", "|---|---|"]
        // Text values escaped, addresses as code (shown exactly, never a link).
        var rows: [(String, String?)] = [
            (label(.title), facts.title.map(markdownEscaped)), (label(.description), facts.description.map(markdownEscaped)),
            ("Canonical", facts.canonical.map(code)), ("Robots", facts.robots.map(code)), (label(.language), facts.lang.map(code)),
            ("Viewport", facts.viewport.map(code)),
        ]
        for key in ["title", "description", "image", "url", "type"] {
            guard let value = facts.openGraph[key] else { continue }
            rows.append(("og:\(key)", key == "image" || key == "url" ? code(value) : markdownEscaped(value)))
        }
        rows += [
            ("Twitter card", facts.twitterCard.map(code)),
            (label(.structuredData), facts.structuredDataTypes.isEmpty ? nil : markdownEscaped(facts.structuredDataTypes.joined(separator: ", "))),
            (label(.links), words.message(.linkCounts(total: facts.links, internal: facts.internalLinks,
                                                     external: facts.externalLinks, nofollow: facts.nofollowLinks))),
            (label(.images), words.message(.imageCounts(total: facts.images, withoutAlt: facts.imagesWithoutAlt))),
            (label(.words), String(facts.wordCount)),
        ]
        for (name, value) in rows {
            lines.append("| \(name) | \(value ?? "—") |")
        }
        if let pages, !pages.isEmpty {
            lines += ["", "## \(label(.pages))", "", "| | | |", "|---|---|---|"]
            for page in pages {
                let status = page.status == 0 ? "—" : String(page.status)
                let title = page.title.map(markdownEscaped) ?? "—"
                lines.append("| \(status) | \(code(page.url)) | \(title)\(page.noindex ? " · noindex" : "") |")
            }
        }
        if !facts.headings.isEmpty {
            // Flat: indenting by level would turn deep headings into a code block.
            lines += ["", "## \(label(.headings))", ""]
            lines += facts.headings.prefix(SEOAudit.maxHeadings).map { "- **h\($0.level)** \(markdownEscaped($0.text))" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Page text as one line of Markdown text (a page's value cannot start a heading, list or block).
    private func markdownEscaped(_ text: String) -> String {
        var out = ""
        for character in text {
            if character.isNewline { out.append(" "); continue }
            // Not `_` or `#`: messages quote URLs (an escape would stay in an autolink), and no line starts with page text.
            if "\\`*[]<>|".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// URLs and other values as code, so they are shown exactly (no escapes in them, no link made of them).
    private func code(_ text: String) -> String {
        let flat = String(text.map { $0.isNewline ? " " : $0 })
        let ticks = flat.contains("`") ? "``" : "`"
        // `|` escaped even in code: it would end a table cell.
        return ticks + " " + flat.replacingOccurrences(of: "|", with: "\\|") + " " + ticks
    }
}

/// What a check says, rendered by `SEOText` (English in CmdsCore; the app has Japanese).
public enum SEOMessage: Sendable {
    case httpStatus(Int)
    case titleMissing, titleLength(characters: Int, width: Int, range: ClosedRange<Int>, title: String),
         titleOK(characters: Int, title: String)
    case descriptionMissing, descriptionLength(characters: Int, width: Int, range: ClosedRange<Int>), descriptionOK(characters: Int)
    case h1Missing, h1OK(String), h1Many(Int)
    case headingsSkipped(String), headingsOK(Int)
    case robotsNoindex(String), robotsNofollow(String), robotsIndexable(String?)
    case robotsTxtDisallowsAll, robotsTxtSitemaps(Int), robotsTxtNoSitemap, robotsTxtMissing
    case canonicalOtherHost(String), canonicalMissing
    case langMissing, viewportMissing
    case openGraphOK, openGraphMissing(String), twitterCardMissing
    case altMissing(missing: Int, images: Int, examples: String), altOK(Int)
    case linksEmpty(Int)
    case structuredDataInvalid(Int), structuredDataMissing
    case httpOnly, mixedContent(Int)
    case thinContent(Int)
    case faviconMissing, charsetMissing
    case hreflangNoSelf, sitemapStatus(Int), sitemapMissingPage, sitemapListsPage
    case lcp(Int), cls(String), ttfb(Int), domSize(Int), pageWeight(Int)
    /// The crawl (`SEOAudit.crawlChecks`).
    case crawlDuplicateTitles(Int), crawlDuplicateDescriptions(Int), crawlMissing(count: Int, what: String),
         crawlNoindex(Int), crawlErrors(Int), crawlOK(Int), crawlNothing
    /// A value shown as it is (the canonical URL, the language…).
    case value(String)
    case linkCounts(total: Int, internal: Int, external: Int, nofollow: Int), imageCounts(total: Int, withoutAlt: Int)
}

/// Headings and row names of the SEO report.
public enum SEOLabel: Sendable {
    case report, problems, warnings, notes, passed, page, title, description, language, structuredData, links, images, words,
         headings, pages
}

/// The words of the SEO check: `english` here (API, CLI, MCP); the app passes a localized one for its report tab.
public struct SEOText: Sendable {
    public var message: @Sendable (SEOMessage) -> String
    public var label: @Sendable (SEOLabel) -> String

    public init(message: @escaping @Sendable (SEOMessage) -> String, label: @escaping @Sendable (SEOLabel) -> String) {
        self.message = message
        self.label = label
    }

    public static let english = SEOText(message: { message in
        switch message {
        case .httpStatus(let status): return "the page answered HTTP \(status)"
        case .titleMissing: return "no <title>"
        case .titleLength(let characters, let width, let range, let title):
            return "\(characters) characters, width \(width) (aim for \(range.lowerBound)–\(range.upperBound); wide characters count 2): \(title)"
        case .titleOK(let characters, let title): return "\(characters) characters: \(title)"
        case .descriptionMissing: return "no <meta name=\"description\">"
        case .descriptionLength(let characters, let width, let range):
            return "\(characters) characters, width \(width) (aim for \(range.lowerBound)–\(range.upperBound); wide characters count 2)"
        case .descriptionOK(let characters): return "\(characters) characters"
        case .h1Missing: return "no <h1>"
        case .h1OK(let text): return "one <h1>: \(text)"
        case .h1Many(let count): return "\(count) <h1> headings (one is usual)"
        case .headingsSkipped(let skips): return "heading levels skipped: \(skips)"
        case .headingsOK(let count): return "\(count) headings in order"
        case .robotsNoindex(let robots): return "<meta name=\"robots\"> asks search engines not to index the page (\(robots))"
        case .robotsNofollow(let robots): return "<meta name=\"robots\"> asks not to follow the links (\(robots))"
        case .robotsIndexable(let robots): return robots.map { "indexable (\($0))" } ?? "indexable (no robots meta tag)"
        case .robotsTxtDisallowsAll: return "robots.txt disallows the whole site for every crawler"
        case .robotsTxtSitemaps(let count): return "robots.txt names \(count) sitemap\(count == 1 ? "" : "s")"
        case .robotsTxtNoSitemap: return "robots.txt has no Sitemap: line"
        case .robotsTxtMissing: return "no robots.txt (everything may be crawled)"
        case .canonicalOtherHost(let canonical): return "points to another host: \(canonical)"
        case .canonicalMissing: return "no <link rel=\"canonical\">"
        case .langMissing: return "no lang attribute on <html>"
        case .viewportMissing: return "no <meta name=\"viewport\"> (the page is not set up for phones)"
        case .openGraphOK: return "og:title, og:description and og:image set"
        case .openGraphMissing(let keys): return "missing \(keys) (link previews)"
        case .twitterCardMissing: return "no twitter:card"
        case .altMissing(let missing, let images, let examples):
            return "\(missing) of \(images) images without alt" + (examples.isEmpty ? "" : ": \(examples)")
        case .altOK(let images): return "all \(images) images have alt"
        case .linksEmpty(let count): return "\(count) links without text or label"
        case .structuredDataInvalid(let count): return "\(count) JSON-LD block\(count == 1 ? " is" : "s are") not valid JSON"
        case .structuredDataMissing: return "no JSON-LD structured data"
        case .httpOnly: return "served over http, not https"
        case .mixedContent(let count): return "\(count) http: resources on an https page"
        case .thinContent(let words): return "\(words) words of text (thin pages rank poorly)"
        case .faviconMissing: return "no <link rel=\"icon\">"
        case .charsetMissing: return "no <meta charset>"
        case .hreflangNoSelf: return "the hreflang alternates do not include this page"
        case .sitemapStatus(let status): return "the sitemap robots.txt names answered HTTP \(status)"
        case .sitemapMissingPage: return "the sitemap does not list this page"
        case .sitemapListsPage: return "the sitemap lists this page"
        case .lcp(let ms): return "Largest Contentful Paint \(ms) ms (good: 2500 or less)"
        case .cls(let value): return "Cumulative Layout Shift \(value) (good: 0.1 or less)"
        case .ttfb(let ms): return "the server answered after \(ms) ms"
        case .domSize(let nodes): return "\(nodes) elements on the page"
        case .pageWeight(let kb): return "\(kb) KB transferred"
        case .crawlDuplicateTitles(let count): return "\(count) pages share a title with another page"
        case .crawlDuplicateDescriptions(let count): return "\(count) pages share a description with another page"
        case .crawlMissing(let count, let what): return count == 1 ? "1 page without \(what)" : "\(count) pages without \(what)"
        case .crawlNoindex(let count): return count == 1 ? "1 page asks not to be indexed" : "\(count) pages ask not to be indexed"
        case .crawlErrors(let count): return count == 1 ? "1 page answered with an error" : "\(count) pages answered with an error"
        case .crawlOK(let count): return count == 1 ? "1 linked page checked" : "\(count) linked pages checked"
        case .crawlNothing: return "No links to other pages of this site to check (or robots.txt disallows them)"
        case .value(let value): return value
        case .linkCounts(let total, let inside, let outside, let nofollow):
            return "\(total) (\(inside) internal, \(outside) external, \(nofollow) nofollow)"
        case .imageCounts(let total, let withoutAlt): return "\(total) (\(withoutAlt) without alt)"
        }
    }, label: { label in
        switch label {
        case .report: return "SEO report"
        case .problems: return "Problems"
        case .warnings: return "Warnings"
        case .notes: return "Notes"
        case .passed: return "Passed"
        case .page: return "Page"
        case .title: return "Title"
        case .description: return "Description"
        case .language: return "Language"
        case .structuredData: return "Structured data"
        case .links: return "Links"
        case .images: return "Images"
        case .words: return "Words"
        case .headings: return "Headings"
        case .pages: return "Linked pages"
        }
    })
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
    public static func checks(_ facts: PageFacts, text: SEOText = .english) -> [SEOCheck] {
        var checks: [SEOCheck] = []
        func add(_ id: String, _ status: SEOCheck.Status, _ message: SEOMessage) {
            checks.append(SEOCheck(id, status, text.message(message)))
        }
        let url = URL(string: facts.url)
        let host = url?.host?.lowercased() ?? ""
        let local = host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1"
            || url?.scheme == "file"

        if let status = facts.status, status >= 400 {
            add("status", .fail, .httpStatus(status))
        }

        let title = facts.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty {
            add("title", .fail, .titleMissing)
        } else if !titleRange.contains(displayWidth(title)) {
            add("title", .warn, .titleLength(characters: title.count, width: displayWidth(title), range: titleRange, title: title))
        } else {
            add("title", .pass, .titleOK(characters: title.count, title: title))
        }

        let description = facts.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if description.isEmpty {
            add("description", .warn, .descriptionMissing)
        } else if !descriptionRange.contains(displayWidth(description)) {
            add("description", .warn, .descriptionLength(characters: description.count, width: displayWidth(description), range: descriptionRange))
        } else {
            add("description", .pass, .descriptionOK(characters: description.count))
        }

        let h1 = facts.headings.filter { $0.level == 1 }
        switch h1.count {
        case 0: add("h1", .fail, .h1Missing)
        case 1: add("h1", .pass, .h1OK(h1[0].text))
        default: add("h1", .warn, .h1Many(h1.count))
        }
        var previous = 0
        var skips: [String] = []
        for heading in facts.headings {
            if previous > 0, heading.level > previous + 1 { skips.append("h\(previous) → h\(heading.level)") }
            previous = heading.level
        }
        if !skips.isEmpty {
            add("headings", .warn, .headingsSkipped(skips.prefix(5).joined(separator: ", ")))
        } else if !facts.headings.isEmpty {
            add("headings", .pass, .headingsOK(facts.headings.count))
        }

        let robots = facts.robots ?? ""
        // Directives, possibly for a crawler (`googlebot: noindex`); `max-image-preview:none` is no `none`.
        let directives = Set(robots.split { $0 == "," || $0 == " " }.map { part -> String in
            let token = part.trimmingCharacters(in: .whitespaces)
            return token.split(separator: ":").count == 2 && !token.hasPrefix("max-") && !token.hasPrefix("unavailable_after")
                ? String(token.split(separator: ":")[1]) : token
        })
        if directives.contains("noindex") || directives.contains("none") {
            add("robots", .fail, .robotsNoindex(robots))
        } else if directives.contains("nofollow") {
            add("robots", .warn, .robotsNofollow(robots))
        } else {
            add("robots", .pass, .robotsIndexable(robots.isEmpty ? nil : robots))
        }
        if let txt = facts.robotsTxt, txt.status != 0 {
            if txt.status == 200, txt.disallowsAll {
                add("robots.txt", .fail, .robotsTxtDisallowsAll)
            } else if txt.status == 200 {
                add("robots.txt", txt.sitemaps > 0 ? .pass : .info,
                    txt.sitemaps > 0 ? .robotsTxtSitemaps(txt.sitemaps) : .robotsTxtNoSitemap)
            } else if txt.status == 404 {
                add("robots.txt", .info, .robotsTxtMissing)
            }
        }

        if let canonical = facts.canonical?.trimmingCharacters(in: .whitespaces), !canonical.isEmpty {
            let target = URL(string: canonical, relativeTo: url)?.absoluteURL
            if target?.host?.lowercased() != host, target?.host != nil {
                add("canonical", .info, .canonicalOtherHost(canonical))
            } else {
                add("canonical", .pass, .value(canonical))
            }
        } else {
            add("canonical", .warn, .canonicalMissing)
        }

        if (facts.lang ?? "").isEmpty { add("lang", .warn, .langMissing) } else { add("lang", .pass, .value(facts.lang!)) }
        if (facts.viewport ?? "").isEmpty {
            add("viewport", .fail, .viewportMissing)
        } else {
            add("viewport", .pass, .value(facts.viewport!))
        }

        let ogMissing = ["title", "description", "image"].filter { (facts.openGraph[$0] ?? "").isEmpty }
        if ogMissing.isEmpty {
            add("open-graph", .pass, .openGraphOK)
        } else {
            add("open-graph", .warn, .openGraphMissing(ogMissing.map { "og:\($0)" }.joined(separator: ", ")))
        }
        if (facts.twitterCard ?? "").isEmpty { add("twitter-card", .info, .twitterCardMissing) }

        if facts.imagesWithoutAlt > 0 {
            let examples = facts.imagesWithoutAltExamples.prefix(3).joined(separator: ", ")
            add("alt", .warn, .altMissing(missing: facts.imagesWithoutAlt, images: facts.images, examples: examples))
        } else if facts.images > 0 {
            add("alt", .pass, .altOK(facts.images))
        }
        if facts.emptyLinks > 0 { add("links", .warn, .linksEmpty(facts.emptyLinks)) }

        if facts.structuredDataErrors > 0 {
            add("structured-data", .warn, .structuredDataInvalid(facts.structuredDataErrors))
        } else if facts.structuredDataTypes.isEmpty {
            add("structured-data", .info, .structuredDataMissing)
        } else {
            add("structured-data", .pass, .value(facts.structuredDataTypes.joined(separator: ", ")))
        }

        if url?.scheme == "http", !local {
            add("https", .warn, .httpOnly)
        } else if facts.mixedContent > 0 {
            add("https", .warn, .mixedContent(facts.mixedContent))
        } else if url?.scheme == "https" {
            add("https", .pass, .value("https"))
        }
        if facts.wordCount < thinContentWords {
            add("content", .info, .thinContent(facts.wordCount))
        }
        if !facts.favicon { add("favicon", .info, .faviconMissing) }
        if (facts.charset ?? "").isEmpty { add("charset", .info, .charsetMissing) }

        if facts.hreflang > 0, facts.hreflangSelf == false { add("hreflang", .warn, .hreflangNoSelf) }
        if let sitemap = facts.sitemap {
            if sitemap.status != 200 {
                add("sitemap", .warn, .sitemapStatus(sitemap.status))
            } else if !sitemap.listsPage {
                add("sitemap", .info, .sitemapMissingPage)
            } else {
                add("sitemap", .pass, .sitemapListsPage)
            }
        }
        if let vitals = facts.vitals {
            if let lcp = vitals.lcp {
                add("lcp", lcp > 4000 ? .fail : lcp > 2500 ? .warn : .pass, .lcp(Int(lcp)))
            }
            if let cls = vitals.cls {
                add("cls", cls > 0.25 ? .fail : cls > 0.1 ? .warn : .pass, .cls(String(format: "%.3f", cls)))
            }
            if let ttfb = vitals.ttfb, ttfb > 1800 { add("ttfb", .warn, .ttfb(Int(ttfb))) }
            if let nodes = vitals.domNodes, nodes > 1500 { add("dom-size", nodes > 3000 ? .warn : .info, .domSize(nodes)) }
            if let bytes = vitals.transferBytes, bytes > 5_000_000 { add("page-weight", .warn, .pageWeight(bytes / 1024)) }
        }
        return checks
    }

    /// Checks over the page and its crawl: duplicate titles or descriptions, pages without them or an h1, noindex pages,
    /// errors. Nothing without a crawl (`pages` nil); a note when it found no page to check.
    public static func crawlChecks(page: PageFacts, pages: [CrawlPage]?, text: SEOText = .english) -> [SEOCheck] {
        guard let pages else { return [] }
        var checks: [SEOCheck] = []
        func add(_ id: String, _ status: SEOCheck.Status, _ message: SEOMessage) {
            checks.append(SEOCheck(id, status, text.message(message)))
        }
        guard !pages.isEmpty else {
            add("site", .info, .crawlNothing)
            return checks
        }
        let ok = pages.filter { (200..<300).contains($0.status) }
        let all = ok + [CrawlPage(url: page.url, status: 200, title: page.title, description: page.description)]
        func duplicates(_ key: (CrawlPage) -> String?) -> Int {
            let values = all.compactMap { key($0)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let counts = Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +)
            return counts.values.filter { $0 > 1 }.reduce(0, +)
        }
        let errors = pages.filter { $0.status >= 400 }.count
        if errors > 0 { add("site-errors", .fail, .crawlErrors(errors)) }
        let titles = duplicates(\.title)
        if titles > 0 { add("site-titles", .warn, .crawlDuplicateTitles(titles)) }
        let descriptions = duplicates(\.description)
        if descriptions > 0 { add("site-descriptions", .warn, .crawlDuplicateDescriptions(descriptions)) }
        let noTitle = ok.filter { ($0.title ?? "").isEmpty }.count
        if noTitle > 0 { add("site-title", .warn, .crawlMissing(count: noTitle, what: "<title>")) }
        let noDescription = ok.filter { ($0.description ?? "").isEmpty }.count
        if noDescription > 0 { add("site-description", .info, .crawlMissing(count: noDescription, what: "a description")) }
        let noH1 = ok.filter { $0.h1 == 0 }.count
        if noH1 > 0 { add("site-h1", .info, .crawlMissing(count: noH1, what: "<h1>")) }
        let noindex = ok.filter(\.noindex).count
        if noindex > 0 { add("site-noindex", .info, .crawlNoindex(noindex)) }
        add("site", .pass, .crawlOK(pages.count))
        return checks
    }

    /// At most this many linked pages are crawled.
    public static let maxCrawl = 50

    /// `callAsyncJavaScript` body: up to `max` links of the page on its own site (not disallowed by robots.txt's `*`
    /// group: `disallowed`), each fetched without cookies (8 s, 2 MB), parsed without running it. Returns `[CrawlPage]`.
    public static let crawlScript = """
        // robots.txt rules of the `*` group: `*` and `$` patterns, the longest match wins, Allow over Disallow on a tie.
        const rule = (p) => { try { return new RegExp('^' + p.replace(/[.+?^{}()|[\\]\\\\]/g, '\\\\$&').replace(/\\*/g, '.*')); } catch (e) { return null; } };
        const rules = [...(disallowed || []).map(p => ({ p, allow: false })), ...(allowed || []).map(p => ({ p, allow: true }))]
          .filter(r => r.p).map(r => ({ ...r, re: rule(r.p) })).filter(r => r.re);
        const blocked = (u) => {
          const path = u.pathname + u.search;
          let best = null;
          for (const r of rules) if (r.re.test(path) && (!best || r.p.length > best.p.length || (r.p.length === best.p.length && r.allow))) best = r;
          return best ? !best.allow : false;
        };
        // Links that do something rather than show a page (sign out, delete…) or that are marked not to follow.
        const action = /(^|[\\/_.?&=-])(log-?out|log-?off|sign-?out|delete|destroy|remove|unsubscribe|revoke|disconnect|deactivate|cancel|reset|purge)([\\/_.?&=-]|$)/i;
        const seen = new Set([location.href.split('#')[0]]);
        const queue = [];
        for (const a of document.querySelectorAll('a[href]')) {
          if (!(a instanceof HTMLAnchorElement) || a.hasAttribute('download') || a.hasAttribute('data-method')
              || /(^|\\s)nofollow(\\s|$)/i.test(a.getAttribute('rel') || '')) continue;
          let u; try { u = new URL(a.getAttribute('href'), location.href); } catch (e) { continue; }
          if (u.origin !== location.origin || !/^https?:$/.test(u.protocol)) continue;
          u.hash = '';
          if (seen.has(u.href) || blocked(u) || action.test(u.pathname + u.search)) continue;
          seen.add(u.href); queue.push(u.href);
          if (queue.length >= max) break;
        }
        const cut = (s) => s == null ? null : String(s).trim().slice(0, 300) || null;
        const one = async (url) => {
          const abort = new AbortController();
          const timer = setTimeout(() => abort.abort(), 8000);
          try {
            const r = await fetch(url, { credentials: 'omit', redirect: 'follow', signal: abort.signal });
            const type = r.headers.get('content-type') || '';
            // Not HTML: not a page (an error still counts); its download stops here.
            if (!/html/i.test(type)) { abort.abort(); return { url, status: r.status >= 400 ? r.status : 0, h1: 0, noindex: false }; }
            const reader = r.body.getReader(); const parts = []; let size = 0;
            while (size < 2000000) { const { done, value } = await reader.read(); if (done) break; parts.push(value); size += value.length; }
            try { reader.cancel(); } catch (e) {}
            const all = new Uint8Array(Math.min(size, 2000000)); let offset = 0;
            for (const p of parts) { const take = p.subarray(0, all.length - offset); all.set(take, offset); offset += take.length; if (offset >= all.length) break; }
            // The encoding: the header's charset, else a <meta> in the first 2 KB, else UTF-8.
            let label = (type.match(/charset=["']?([\\w.:-]+)/i) || [])[1];
            if (!label) label = (new TextDecoder('latin1').decode(all.subarray(0, 2048)).match(/<meta[^>]+charset=["']?([\\w.:-]+)/i) || [])[1];
            let decoder; try { decoder = new TextDecoder(label || 'utf-8'); } catch (e) { decoder = new TextDecoder(); }
            const doc = new DOMParser().parseFromString(decoder.decode(all), 'text/html');
            const meta = (s) => { const e = doc.querySelector(s); return e ? (e.getAttribute('content') || '').trim() : null; };
            const robots = [meta('meta[name="robots" i]'), meta('meta[name="googlebot" i]')].filter(Boolean).join(',').toLowerCase();
            const canonical = doc.querySelector('link[rel="canonical" i]');
            // Redirected: the page it ended at (two links to one page are one page).
            const final = r.redirected && r.url ? r.url.split('#')[0] : url;
            return { url: final, status: r.status, title: cut(doc.title), description: cut(meta('meta[name="description" i]')),
                     h1: doc.querySelectorAll('h1').length, canonical: canonical ? cut(canonical.getAttribute('href')) : null,
                     noindex: /(^|[,\\s])(noindex|none)([,\\s]|$)/.test(robots) };
          } catch (e) {
            return { url, status: 0, h1: 0, noindex: false };
          } finally { clearTimeout(timer); }
        };
        const results = [];
        for (let i = 0; i < queue.length; i += 4) results.push(...await Promise.all(queue.slice(i, i + 4).map(one)));
        const pages = new Set([location.href.split('#')[0]]);
        return results.filter(p => p.status === 0 || p.status >= 400 || !pages.has(p.url) && pages.add(p.url));
        """

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
        let robotsTxt = null, sitemap = null;
        if (/^https?:$/.test(location.protocol)) {
          // A server that does not answer skips the check (5 s), not the whole report.
          const abort = new AbortController();
          const timer = setTimeout(() => abort.abort(), 5000);
          try {
            const r = await fetch(location.origin + '/robots.txt', { credentials: 'omit', redirect: 'follow', signal: abort.signal });
            const body = r.ok && /^text\\/plain/i.test(r.headers.get('content-type') || 'text/plain')
              ? (await r.text()).slice(0, 500000) : '';
            // Groups: consecutive User-agent lines, then their rules. The `*` group disallowing `/` (with no Allow)
            // shuts out every crawler without a group of its own.
            let agents = [], inRules = false, starDisallowsAll = false, starAllows = false, sitemaps = 0, firstSitemap = null;
            const disallowed = [], allowed = [];
            for (const raw of body.split(/\\r?\\n/)) {
              const line = raw.replace(/#.*/, '').trim();
              const m = line.match(/^([A-Za-z-]+)\\s*:\\s*(.*)$/); if (!m) continue;
              const key = m[1].toLowerCase(), value = m[2].trim();
              if (key === 'user-agent') { if (inRules) { agents = []; inRules = false; } agents.push(value); continue; }
              if (key === 'sitemap') { sitemaps++; if (!firstSitemap) firstSitemap = value; continue; }
              if (key !== 'allow' && key !== 'disallow') continue;
              inRules = true;
              if (!agents.includes('*')) continue;
              if (key === 'disallow' && value === '/') starDisallowsAll = true;
              if (key === 'disallow' && value !== '' && disallowed.length < 200) disallowed.push(value);
              if (key === 'allow' && value !== '') { starAllows = true; if (allowed.length < 200) allowed.push(value); }
            }
            robotsTxt = { status: r.status, disallowsAll: starDisallowsAll && !starAllows, sitemaps, disallowed, allowed };
            // The first sitemap, on this site only (5 s, 5 MB; gzip unpacked): does it list this page? A sitemap index:
            // its first five sitemaps on this site.
            if (firstSitemap) {
              try {
                const read = async (url) => {
                  const s = await fetch(url, { credentials: 'omit', redirect: 'follow', signal: abort.signal });
                  if (!s.ok || !s.body) return { status: s.status, text: '' };
                  let stream = s.body;
                  if (/\\.gz$/i.test(new URL(url).pathname) && !/xml|text/i.test(s.headers.get('content-type') || '')
                      && typeof DecompressionStream !== 'undefined') stream = stream.pipeThrough(new DecompressionStream('gzip'));
                  const reader = stream.getReader(); let size = 0; const parts = [];
                  while (size < 5000000) { const { done, value } = await reader.read(); if (done) break; parts.push(value); size += value.length; }
                  try { reader.cancel(); } catch (e) {}
                  const all = new Uint8Array(Math.min(size, 5000000)); let offset = 0;
                  for (const p of parts) { const take = p.subarray(0, all.length - offset); all.set(take, offset); offset += take.length; if (offset >= all.length) break; }
                  return { status: s.status, text: new TextDecoder().decode(all) };
                };
                const locs = (text) => [...text.matchAll(/<loc>\\s*(?:<!\\[CDATA\\[)?\\s*([^<\\]]*?)\\s*(?:\\]\\]>)?\\s*<\\/loc>/gi)]
                  .map(m => m[1].replace(/&amp;/g, '&').trim());
                const sm = new URL(firstSitemap, location.href);
                if (sm.origin === location.origin) {
                  const first = await read(sm.href);
                  let listed = locs(first.text);
                  if (/<sitemapindex/i.test(first.text)) {
                    const children = listed.filter(u => { try { return new URL(u).origin === location.origin; } catch (e) { return false; } }).slice(0, 5);
                    listed = [];
                    for (const child of children) { try { listed.push(...locs((await read(child)).text)); } catch (e) {} }
                  }
                  const page = location.href.split('#')[0];
                  const forms = [page, page.endsWith('/') ? page.slice(0, -1) : page + '/'];
                  sitemap = { url: sm.href, status: first.status, listsPage: listed.some(u => forms.includes(u)) };
                }
              } catch (e) {}
            }
          } catch (e) { robotsTxt = { status: 0, disallowsAll: false, sitemaps: 0 }; }
          clearTimeout(timer);
        }
        // Loading measures (what WebKit reports; 300 ms for buffered entries).
        const vitals = await new Promise(resolve => {
          let lcp = null, cls = 0, clsSeen = false;
          try { new PerformanceObserver(l => { for (const e of l.getEntries()) lcp = e.startTime; }).observe({ type: 'largest-contentful-paint', buffered: true }); } catch (e) {}
          try { new PerformanceObserver(l => { for (const e of l.getEntries()) { clsSeen = true; if (!e.hadRecentInput) cls += e.value; } }).observe({ type: 'layout-shift', buffered: true }); } catch (e) {}
          setTimeout(() => {
            const nav = performance.getEntriesByType('navigation')[0];
            const fcpEntry = performance.getEntriesByType('paint').find(e => e.name === 'first-contentful-paint');
            const transfer = (nav ? nav.transferSize || 0 : 0) + performance.getEntriesByType('resource').reduce((n, e) => n + (e.transferSize || 0), 0);
            resolve({ lcp, cls: clsSeen ? cls : null, fcp: fcpEntry ? fcpEntry.startTime : null,
                      ttfb: nav && nav.responseStart > 0 ? nav.responseStart : null, transferBytes: transfer || null,
                      domNodes: document.getElementsByTagName('*').length });
          }, 300);
        });
        const alternates = [...document.querySelectorAll('link[rel="alternate" i][hreflang]')].map(l => l.href.split('#')[0]);
        const hreflangSelf = alternates.length ? alternates.includes(location.href.split('#')[0]) : null;
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
          favicon: !!document.querySelector('link[rel~="icon" i]'), wordCount: words, status, mixedContent: mixed, robotsTxt,
          vitals, hreflangSelf, sitemap
        };
        """
}
