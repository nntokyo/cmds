import CmdsCore
import Foundation

// `cmds browser source|seo`: web development tools of browser panes (docs/reference/cli.md).
extension CLI {
    static let sourceCommand = Command(
        name: "browser source",
        usage: "browser source [--pane P] [--rendered] [--open] [-o FILE]",
        summary: "Print the HTML of a browser pane's page.",
        details: """
            The HTML the server sent (asked again from the page, with its cookies; usually from the cache), or with
            --rendered the DOM as it is now (after scripts ran). At most \(PageSource.maxBytes / 1024 / 1024) MB (cut
            beyond, with a note on stderr). -o FILE writes it there instead of stdout; --open also shows it in a
            source tab beside the pane (View › Developer › View Page Source).
            \(browserPaneNote)
            """,
        options: ["pane", "output"], flags: ["rendered", "open"], aliases: ["o": "output"]
    ) { ctx in
        try ctx.args.expectPositionals(0...0, usage: "cmds browser source [--pane P] [--rendered] [--open] [-o FILE]")
        let result = try devToolsCall(ctx, "browser.source", [
            "rendered": ctx.args.has("rendered") ? true : nil,
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
    }

    static let seoCommand = Command(
        name: "browser seo",
        usage: "browser seo [--pane P] [--open]",
        summary: "Check what a browser pane's page declares for search engines and link previews.",
        details: """
            Title and description length, h1 and heading order, canonical, robots meta tag and robots.txt, lang and
            viewport, Open Graph and Twitter card, image alt, links without text, JSON-LD structured data, https and
            mixed content, word count, favicon. Prints a score (100 less 15 per problem and 5 per warning) and one line
            per check: ✗ problem, ! warning, i note, ✓ passed. Exit status 1 when a check failed. --open also shows the
            report in a preview tab beside the pane (View › Developer › SEO Report); --json gives the checks and the
            page facts.
            \(browserPaneNote)
            """,
        options: ["pane"], flags: ["open"]
    ) { ctx in
        try ctx.args.expectPositionals(0...0, usage: "cmds browser seo [--pane P] [--open]")
        let result = try devToolsCall(ctx, "browser.seo", ["open": ctx.args.has("open") ? true : nil])
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
