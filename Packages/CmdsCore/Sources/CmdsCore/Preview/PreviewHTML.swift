import Foundation

/// How a preview pane shows a file: rendered by cmds (Markdown, diffs) or by Quick Look.
public enum PreviewFormat: String, Sendable {
    case markdown
    case diff
    case quickLook

    /// From the file name: `.md`/`.markdown` → markdown, `.diff`/`.patch` → diff, anything else Quick Look.
    public static func forFile(_ path: String) -> PreviewFormat {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd": return .markdown
        case "diff", "patch": return .diff
        default: return .quickLook
        }
    }

    /// Text formats are read (and capped) by cmds itself.
    public static let maxRenderedBytes = 8 * 1024 * 1024
}

/// Shared page shell, escaping and link policy for the HTML that preview panes render.
public enum PreviewHTML {
    public static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    /// Link/image targets allowed in rendered documents: http(s), mailto, file, and scheme-less (relative paths,
    /// `#anchors`). Anything else (`javascript:`, `data:`…) is dropped (nil).
    public static func safeURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let colon = trimmed.firstIndex(of: ":"),
           trimmed[..<colon].range(of: #"^[A-Za-z][A-Za-z0-9+.-]*$"#, options: .regularExpression) != nil {
            let scheme = trimmed[..<colon].lowercased()
            return ["http", "https", "mailto", "file"].contains(scheme) ? trimmed : nil
        }
        return trimmed
    }

    public static func page(title: String, bodyClass: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src * data: blob:; style-src 'unsafe-inline'; media-src *">
        <meta name="color-scheme" content="light dark">
        <title>\(escape(title))</title>
        <style>\(css)</style>
        </head><body class="\(bodyClass)">
        \(body)
        </body></html>
        """
    }

    /// GitHub-like styling, light and dark.
    public static let css = """
        :root { color-scheme: light dark; --fg:#1f2328; --muted:#59636e; --bg:#ffffff; --border:#d1d9e0; --code-bg:#f6f8fa;
          --link:#0969da; --add-bg:#dafbe1; --add-fg:#116329; --del-bg:#ffebe9; --del-fg:#a40e26; --hunk-bg:#ddf4ff;
          --hunk-fg:#0550ae; --meta-bg:#f6f8fa; }
        @media (prefers-color-scheme: dark) { :root { --fg:#e6edf3; --muted:#9198a1; --bg:#0d1117; --border:#3d444d;
          --code-bg:#151b23; --link:#4493f8; --add-bg:rgba(46,160,67,0.18); --add-fg:#3fb950; --del-bg:rgba(248,81,73,0.18);
          --del-fg:#f85149; --hunk-bg:rgba(56,139,253,0.15); --hunk-fg:#79c0ff; --meta-bg:#151b23; } }
        html { background: var(--bg); }
        body { margin: 0; color: var(--fg); background: var(--bg);
          font: 14px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; -webkit-text-size-adjust: 100%; }
        body.markdown { padding: 20px 28px 40px; max-width: 900px; }
        a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
        h1, h2, h3, h4, h5, h6 { margin: 24px 0 12px; font-weight: 600; line-height: 1.25; }
        h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
        h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
        h3 { font-size: 1.25em; } h4 { font-size: 1em; } h5 { font-size: .875em; } h6 { font-size: .85em; color: var(--muted); }
        body > :first-child { margin-top: 0; }
        p, ul, ol, blockquote, pre, table { margin: 0 0 16px; }
        ul, ol { padding-left: 2em; } li + li { margin-top: .25em; } li > ul, li > ol { margin-bottom: 0; }
        li.task { list-style: none; } li.task input { margin: 0 .3em 0 -1.4em; vertical-align: middle; }
        blockquote { padding: 0 1em; color: var(--muted); border-left: .25em solid var(--border); }
        code, pre { font: 12px/1.45 ui-monospace, "SF Mono", Menlo, monospace; }
        code { padding: .2em .4em; background: var(--code-bg); border-radius: 6px; font-size: 85%; }
        pre { padding: 16px; overflow: auto; background: var(--code-bg); border-radius: 6px; }
        pre code { padding: 0; background: none; font-size: 100%; }
        hr { height: .25em; padding: 0; margin: 24px 0; background: var(--border); border: 0; }
        table { border-collapse: collapse; display: block; overflow: auto; }
        th, td { padding: 6px 13px; border: 1px solid var(--border); } th { font-weight: 600; }
        tr:nth-child(2n) td { background: var(--code-bg); }
        img { max-width: 100%; }
        body.diff { padding: 0; }
        .file { margin: 12px; border: 1px solid var(--border); border-radius: 6px; overflow: hidden; }
        .file-name { padding: 8px 12px; background: var(--meta-bg); border-bottom: 1px solid var(--border);
          font: 600 12px ui-monospace, "SF Mono", Menlo, monospace; }
        .file-name .stat { float: right; font-weight: 400; } .stat .a { color: var(--add-fg); } .stat .d { color: var(--del-fg); }
        table.diff { display: table; width: 100%; margin: 0; border: 0; font: 12px/1.5 ui-monospace, "SF Mono", Menlo, monospace; }
        table.diff td { border: 0; padding: 0 8px; white-space: pre-wrap; word-break: break-all; background: none; vertical-align: top; }
        table.diff td.ln { width: 1%; min-width: 3ch; text-align: right; color: var(--muted); user-select: none; white-space: nowrap; }
        table.diff tr.add td { background: var(--add-bg); } table.diff tr.del td { background: var(--del-bg); }
        table.diff tr.add td.code::before { content: "+"; color: var(--add-fg); }
        table.diff tr.del td.code::before { content: "-"; color: var(--del-fg); }
        table.diff tr.ctx td.code::before { content: " "; }
        table.diff tr.hunk td { background: var(--hunk-bg); color: var(--hunk-fg); }
        table.diff tr.meta td { color: var(--muted); }
        """
}
