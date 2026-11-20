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
          if (!response.ok && !fetchAgain && response.status === 504) return dom(true);
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

    /// The labels of `markdown` (English unless the app passes its own).
    private var words: SEOText = .english

    private enum CodingKeys: String, CodingKey { case url, score, checks, facts }

    public static func == (lhs: SEOReport, rhs: SEOReport) -> Bool {
        lhs.url == rhs.url && lhs.score == rhs.score && lhs.checks == rhs.checks && lhs.facts == rhs.facts
    }

    /// `text`: the language of the messages and of `markdown` (the API and CLI keep English).
    public init(facts: PageFacts, text: SEOText = .english) {
        words = text
        url = facts.url
        checks = SEOAudit.checks(facts, text: text).enumerated().sorted { lhs, rhs in
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
    /// A value shown as it is (the canonical URL, the language…).
    case value(String)
    case linkCounts(total: Int, internal: Int, external: Int, nofollow: Int), imageCounts(total: Int, withoutAlt: Int)
}

/// Headings and row names of the SEO report.
public enum SEOLabel: Sendable {
    case report, problems, warnings, notes, passed, page, title, description, language, structuredData, links, images, words,
         headings
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
          // A server that does not answer skips the check (5 s), not the whole report.
          const abort = new AbortController();
          const timer = setTimeout(() => abort.abort(), 5000);
          try {
            const r = await fetch(location.origin + '/robots.txt', { credentials: 'omit', redirect: 'follow', signal: abort.signal });
            const body = r.ok && /^text\\/plain/i.test(r.headers.get('content-type') || 'text/plain')
              ? (await r.text()).slice(0, 500000) : '';
            // Groups: consecutive User-agent lines, then their rules. The `*` group disallowing `/` (with no Allow)
            // shuts out every crawler without a group of its own.
            let agents = [], inRules = false, starDisallowsAll = false, starAllows = false, sitemaps = 0;
            for (const raw of body.split(/\\r?\\n/)) {
              const line = raw.replace(/#.*/, '').trim();
              const m = line.match(/^([A-Za-z-]+)\\s*:\\s*(.*)$/); if (!m) continue;
              const key = m[1].toLowerCase(), value = m[2].trim();
              if (key === 'user-agent') { if (inRules) { agents = []; inRules = false; } agents.push(value); continue; }
              if (key === 'sitemap') { sitemaps++; continue; }
              if (key !== 'allow' && key !== 'disallow') continue;
              inRules = true;
              if (!agents.includes('*')) continue;
              if (key === 'disallow' && value === '/') starDisallowsAll = true;
              if (key === 'allow' && value !== '') starAllows = true;
            }
            robotsTxt = { status: r.status, disallowsAll: starDisallowsAll && !starAllows, sitemaps };
          } catch (e) { robotsTxt = { status: 0, disallowsAll: false, sitemaps: 0 }; }
          clearTimeout(timer);
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
