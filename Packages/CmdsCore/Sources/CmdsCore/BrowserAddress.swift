import Foundation

// What a browser pane's address bar and `browser.navigate` / `browser.open` make of the text typed (#338), and the
// English reasons the API gives when a page fails to load. The app side is App/Sources/Browser/BrowserPane.swift and
// BrowserPane+LoadErrors.swift.

public enum BrowserAddress {
    /// Schemes typed without `//` that are kept as they are (`mailto:a@b.com`, `about:blank`).
    static let knownSchemes: Set<String> = ["about", "data", "file", "mailto", "tel", "sms", "facetime", "facetime-audio"]
    /// Schemes another app handles (Mail, FaceTime, Messages): the pane hands them to macOS instead of loading them.
    static let externalSchemes: Set<String> = ["mailto", "tel", "sms", "facetime", "facetime-audio"]
    /// Schemes WebKit loads in the pane.
    static let pageSchemes: Set<String> = ["http", "https", "file", "about", "data", "blob"]
    /// Endings of file names that are also top-level domains or look like one (`README.md`, `main.rs`): searched for,
    /// not opened as a host. Type `https://` to open such a site.
    static let fileExtensions: Set<String> = [
        "md", "markdown", "txt", "json", "html", "htm", "xml", "yml", "yaml", "toml", "ini", "conf", "cfg", "lock", "log",
        "csv", "tsv", "sh", "zsh", "bash", "py", "rb", "rs", "go", "js", "mjs", "cjs", "ts", "tsx", "jsx", "swift", "kt",
        "java", "c", "h", "cpp", "hpp", "m", "mm", "cs", "pl", "php", "sql", "db", "png", "jpg", "jpeg", "gif", "svg",
        "webp", "pdf", "zip", "gz", "tar", "dmg", "pkg", "plist", "mov", "mp3", "mp4", "env", "bak", "tmp", "lua", "hs",
        "ml", "ex", "exs", "css", "scss", "vue", "dart", "rst", "tex",
    ]

    /// The URL to load for `raw`, or nil when there is nothing to load (empty, or a URL that does not parse, such as
    /// `http://exa mple.com`).
    ///
    /// - `/path` and `~/path`: a file URL.
    /// - `scheme://…` and the `knownSchemes` (`mailto:`, `tel:`, `about:`, `data:`): that URL; characters a URL cannot
    ///   hold (spaces) are percent-encoded, and web addresses need a host without spaces.
    /// - `localhost`, `*.localhost`, IP addresses and `name:port`: `http://`.
    /// - A name with a dot whose last label is a plausible top-level domain (letters, not a common file extension):
    ///   `https://`.
    /// - Anything else (`1.5`, `README.md`, words): a web search.
    public static func url(fromUserInput raw: String, homeDirectory: String = NSHomeDirectory()) -> URL? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if input.hasPrefix("/") { return URL(fileURLWithPath: input) }
        if input == "~" || input.hasPrefix("~/") {
            return URL(fileURLWithPath: homeDirectory + input.dropFirst())
        }
        if let separator = input.range(of: "://") {
            let scheme = String(input[..<separator.lowerBound])
            guard isScheme(scheme) else { return search(input) }
            let authority = input[separator.upperBound...].prefix { !"/?#".contains($0) }
            guard !authority.contains(where: \.isWhitespace), let url = URL(string: input) else { return nil }
            if ["http", "https", "ws", "wss", "ftp"].contains(scheme.lowercased()),
               (url.host(percentEncoded: false) ?? "").isEmpty { return nil }
            return url
        }
        if let colon = input.firstIndex(of: ":"), knownSchemes.contains(input[..<colon].lowercased()) {
            return URL(string: input)
        }
        guard !input.contains(where: \.isWhitespace) else { return search(input) }
        let hostAndPort = String(input.prefix { !"/?#".contains($0) })
        guard let scheme = webScheme(hostAndPort: hostAndPort) else { return search(input) }
        return URL(string: scheme + "://" + input) ?? search(input)
    }

    /// `true` for a URL another app opens (Mail for `mailto:`, FaceTime for `tel:`).
    public static func opensExternally(_ url: URL) -> Bool {
        externalSchemes.contains(url.scheme?.lowercased() ?? "")
    }

    /// `true` for a URL WebKit can show in the pane (web pages, files, `about:`, `data:`, `blob:`).
    public static func loadsInPane(_ url: URL) -> Bool {
        pageSchemes.contains(url.scheme?.lowercased() ?? "")
    }

    private static func isScheme(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*$"#, options: .regularExpression) != nil
    }

    private static func search(_ input: String) -> URL? {
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: input)]
        return components.url
    }

    /// `http` for local hosts, addresses and ports, `https` for a domain name, nil: not a host.
    private static func webScheme(hostAndPort: String) -> String? {
        if hostAndPort.range(of: #"^\[[0-9A-Fa-f:.]+\](:\d{1,5})?$"#, options: .regularExpression) != nil { return "http" }
        var host = hostAndPort
        var hasPort = false
        if let colon = hostAndPort.lastIndex(of: ":") {
            let port = hostAndPort[hostAndPort.index(after: colon)...]
            guard !port.isEmpty, port.count <= 5, port.allSatisfy(\.isASCIIDigit) else { return nil }
            host = String(hostAndPort[..<colon])
            hasPort = true
        }
        let lower = host.lowercased()
        let labels = lower.split(separator: ".", omittingEmptySubsequences: false)
        guard !lower.isEmpty, labels.allSatisfy({ isLabel($0) }) else { return nil }
        if lower == "localhost" || lower.hasSuffix(".localhost") { return "http" }
        if lower.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil { return "http" }
        if hasPort { return "http" }
        guard labels.count > 1, let tld = labels.last, isTopLevelDomain(tld) else { return nil }
        return "https"
    }

    private static func isLabel(_ label: Substring) -> Bool {
        !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-")
            && label.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
    }

    private static func isTopLevelDomain(_ label: Substring) -> Bool {
        if label.hasPrefix("xn--") { return label.count > 4 }
        return label.count >= 2 && label.allSatisfy(\.isLetter) && !fileExtensions.contains(String(label))
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// Why a browser pane's page did not load, in English for the API (`browser.get_url`'s `error`); the pane itself shows
/// the system's localized description.
public enum BrowserLoadError {
    public static let urlErrorDomain = "NSURLErrorDomain"
    public static let webKitErrorDomain = "WebKitErrorDomain"

    /// Errors that are no failure: a navigation replaced by another (-999), one that became a download (102) or one a
    /// plug-in took over (204).
    public static func isIgnored(domain: String, code: Int) -> Bool {
        (domain == urlErrorDomain && code == -999) || (domain == webKitErrorDomain && [102, 204].contains(code))
    }

    /// The server's certificate is not trusted (expired, not yet valid, unknown or untrusted root).
    public static func isCertificateError(domain: String, code: Int) -> Bool {
        domain == urlErrorDomain && (-1204 ... -1201).contains(code)
    }

    /// The reason in English, e.g. `could not connect to the server (NSURLErrorDomain -1004)`.
    public static func reason(domain: String, code: Int) -> String {
        let text: String? = switch (domain, code) {
        case (urlErrorDomain, -1000): "bad URL"
        case (urlErrorDomain, -1001): "the request timed out"
        case (urlErrorDomain, -1002): "unsupported URL"
        case (urlErrorDomain, -1003): "server not found"
        case (urlErrorDomain, -1004): "could not connect to the server"
        case (urlErrorDomain, -1005): "the network connection was lost"
        case (urlErrorDomain, -1006): "DNS lookup failed"
        case (urlErrorDomain, -1007): "too many redirects"
        case (urlErrorDomain, -1009): "not connected to the internet"
        case (urlErrorDomain, -1011): "bad server response"
        case (urlErrorDomain, -1012): "authentication was cancelled"
        case (urlErrorDomain, -1013): "authentication is required"
        case (urlErrorDomain, -1100): "file does not exist"
        case (urlErrorDomain, -1102): "no permission to read the file"
        case (urlErrorDomain, -1200): "a secure connection could not be made"
        case (urlErrorDomain, -1201): "the server's certificate has expired"
        case (urlErrorDomain, -1202): "the server's certificate is not trusted"
        case (urlErrorDomain, -1203): "the server's certificate has an unknown root"
        case (urlErrorDomain, -1204): "the server's certificate is not yet valid"
        case (urlErrorDomain, -1205): "the server did not accept the certificate"
        case (urlErrorDomain, -1206): "the server requires a client certificate"
        case (webKitErrorDomain, 100): "the content cannot be shown"
        case (webKitErrorDomain, 101): "the URL cannot be shown"
        default: nil
        }
        return "\(text ?? "load failed") (\(domain) \(code))"
    }

    /// `browser.get_url`'s `error` after the page's WebContent process ended.
    public static let processTerminated = "the page's web content process ended unexpectedly"
}
