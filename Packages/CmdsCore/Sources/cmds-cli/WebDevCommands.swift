import CmdsCore
import Foundation

// `cmds browser source|seo`: web development tools of browser panes (docs/reference/cli.md).
extension CLI {
    static let sourceCommand = Command(
        name: "browser source",
        usage: "browser source [--pane P] [--rendered] [--fetch] [--open] [-o FILE]",
        summary: "Print the HTML of a browser pane's page.",
        details: """
            The HTML the server sent, from the browser's cache, or with --rendered the DOM as it is now (after scripts
            ran). A page that is not in the cache gives its DOM (with a note on stderr); --fetch asks the server again
            instead (a GET with the page's cookies, which repeats what the URL does, e.g. a one-time link). At most \(PageSource.maxBytes / 1024 / 1024) MB (cut
            beyond, with a note on stderr). -o FILE writes it there instead of stdout; --open also shows it in a
            source tab beside the pane (View › Developer › View Page Source).
            \(browserPaneNote)
            """,
        options: ["pane", "output"], flags: ["rendered", "fetch", "open"], aliases: ["o": "output"]
    ) { ctx in
        try ctx.args.expectPositionals(0...0, usage: "cmds browser source [--pane P] [--rendered] [--fetch] [--open] [-o FILE]")
        let result = try devToolsCall(ctx, "browser.source", [
            "rendered": ctx.args.has("rendered") ? true : nil,
            "fetch": ctx.args.has("fetch") ? true : nil,
            "open": ctx.args.has("open") ? true : nil,
        ])
        if ctx.json { return ctx.printJSON(result) }
        let source = result["source"]?.stringValue ?? ""
        if let output = ctx.args[option: "output"], output != "-" {
            do {
                try Data(source.utf8).write(to: URL(fileURLWithPath: absolutePath(output)))
            } catch {
                throw CLIError.failure("cannot write \(output): \(error.localizedDescription)")
            }
        } else {
            print(source, terminator: source.hasSuffix("\n") ? "" : "\n")
        }
        if result["truncated"]?.boolValue == true { printError("(cut at \(PageSource.maxBytes / 1024 / 1024) MB)") }
        if result["notCached"]?.boolValue == true { printError("(not in the cache: this is the DOM; --fetch asks the server again)") }
    }

    static let seoCommand = Command(
        name: "browser seo",
        usage: "browser seo [--pane P] [--crawl N] [--open]",
        summary: "Check what a browser pane's page declares for search engines and link previews.",
        details: """
            Title and description length, h1 and heading order, canonical, robots meta tag and robots.txt, lang and
            viewport, Open Graph and Twitter card, image alt, links without text, JSON-LD structured data, https and
            mixed content, word count, favicon, hreflang, the sitemap, and loading (LCP, CLS, time to first byte, page size,
            elements). --crawl N (at most \(SEOAudit.maxCrawl)) also fetches up to N linked pages of the same site
            (without cookies, skipping what robots.txt disallows) and checks duplicate titles and descriptions, missing
            titles, h1 and descriptions, noindex pages and errors. Prints a score (100 less 15 per problem and 5 per warning) and one line
            per check: ✗ problem, ! warning, i note, ✓ passed. Exit status 1 when a check failed. --open also shows the
            report in a preview tab beside the pane (View › Developer › SEO Report); --json gives the checks and the
            page facts.
            \(browserPaneNote)
            """,
        options: ["pane", "crawl"], flags: ["open"]
    ) { ctx in
        try ctx.args.expectPositionals(0...0, usage: "cmds browser seo [--pane P] [--crawl N] [--open]")
        let crawl = try ctx.args.int("crawl")
        if let crawl, !(1...SEOAudit.maxCrawl).contains(crawl) { throw CLIError.usage("--crawl must be 1 to \(SEOAudit.maxCrawl)") }
        let result = try devToolsCall(ctx, "browser.seo", ["open": ctx.args.has("open") ? true : nil,
                                                           "crawl": crawl.map { .number(Double($0)) }], timeout: 200)
        if ctx.json {
            ctx.printJSON(result)
        } else {
            print(result["text"]?.stringValue ?? "")
        }
        let checks = (try? result["checks"]?.decode([SEOCheck].self)) ?? []
        let failed = checks.filter { $0.status == .fail }.count
        if failed > 0 { throw CLIError.failure("\(failed) check\(failed == 1 ? "" : "s") failed") }
    }
}
