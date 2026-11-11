import Foundation

// What a browser pane does when a page opens a window, shows a dialog or downloads a file (#235;
// docs/guide/workspaces-and-panes.md "Pop-ups, dialogs and downloads"). The app side is
// App/Sources/Browser/BrowserPageDelegate.swift.

/// Where a page's request for a new window goes.
public enum BrowserNewWindow: Equatable, Sendable {
    /// A small window of its own whose page keeps `window.opener` (sign-in and payment pop-ups).
    case popup
    /// A new browser pane beside the pane (a `target="_blank"` link; such links get no opener anyway).
    case newPane(URL)
    /// The pane loads it itself (no pane could be opened).
    case samePane(URL)
    /// Nothing opens (`window.open` returns null): the pane is not on screen.
    case refuse

    /// - Parameters:
    ///   - isLinkActivation: a link the user (or `browser.click`) followed, not a script's `window.open` or a form.
    ///   - hasWindowFeatures: the page asked for a size, position or bars (`window.open(url, name, "width=…")`).
    ///   - url: the address of the request (nil or not a web page: a pop-up the script fills itself).
    ///   - paneOnScreen: the pane is in a visible window (not a hidden workspace or an off-screen snapshot).
    ///   - canOpenPane: the app can split the pane.
    public static func decide(isLinkActivation: Bool, hasWindowFeatures: Bool, url: URL?, paneOnScreen: Bool,
                              canOpenPane: Bool) -> BrowserNewWindow {
        let webURL = url.flatMap { isWebPage($0) ? $0 : nil }
        if isLinkActivation, !hasWindowFeatures, let webURL {
            return canOpenPane ? .newPane(webURL) : .samePane(webURL)
        }
        // Pop-ups keep the opener, which only a web view WebKit hands its configuration to can do.
        return paneOnScreen ? .popup : .refuse
    }

    /// http, https or file.
    static func isWebPage(_ url: URL) -> Bool {
        ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "")
    }
}

/// The size of a pop-up window's page.
public enum BrowserPopupSize {
    /// When the page gives no size.
    public static let defaultSize = CGSize(width: 500, height: 640)
    public static let minimum = CGSize(width: 320, height: 240)
    public static let maximum = CGSize(width: 1600, height: 1200)
    /// Kept free around a pop-up on the screen (title bar, Dock).
    public static let screenMargin: CGFloat = 40

    /// The page's `width` / `height` (default when missing or not positive), between `minimum` and `maximum` and within
    /// `available` (the screen's visible size) less the margin.
    public static func clamped(width: Double?, height: Double?, available: CGSize) -> CGSize {
        func clamp(_ value: Double?, fallback: CGFloat, minimum: CGFloat, maximum: CGFloat, screen: CGFloat) -> CGFloat {
            let wanted = value.flatMap { $0.isFinite && $0 > 0 ? CGFloat($0) : nil } ?? fallback
            let upper = max(min(maximum, screen - screenMargin), 1)
            return min(max(wanted, min(minimum, upper)), upper).rounded()
        }
        return CGSize(width: clamp(width, fallback: defaultSize.width, minimum: minimum.width, maximum: maximum.width,
                                   screen: available.width),
                      height: clamp(height, fallback: defaultSize.height, minimum: minimum.height,
                                    maximum: maximum.height, screen: available.height))
    }
}

/// Files a browser pane downloads.
public enum BrowserDownloadName {
    /// The name when the server suggests none.
    public static let fallback = "download"
    /// Extensions kept together when a number is added (`archive 2.tar.gz`).
    static let compoundExtensions = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst", "tar.lz", "tar.Z"]
    /// Longest name, in UTF-8 bytes (APFS allows 255).
    static let maxBytes = 200
    /// The highest number `unique` tries before a random tag.
    static let maxCopyNumber = 9_999

    /// A plain file name from the server's suggestion: no folders, no hidden or control characters, not too long.
    public static func sanitized(_ suggested: String?) -> String {
        var name = (suggested ?? "").components(separatedBy: "/").last ?? ""
        name = String(name.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || scalar == ":" ? "_" : Character(scalar)
        })
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return fallback }
        guard name.utf8.count > maxBytes else { return name }
        let (stem, ext) = split(name)
        let suffix = ext.isEmpty ? "" : "." + ext
        var shortened = stem
        while !shortened.isEmpty, shortened.utf8.count + suffix.utf8.count > maxBytes { shortened.removeLast() }
        return shortened.isEmpty ? fallback + suffix : shortened + suffix
    }

    /// `name` in `directory`, or `name 2.ext`, `name 3.ext`… when that exists (as the Finder numbers copies).
    public static func unique(_ name: String, in directory: URL, exists: (URL) -> Bool) -> URL {
        let first = directory.appendingPathComponent(name)
        guard exists(first) else { return first }
        let (stem, ext) = split(name)
        func tagged(_ tag: String) -> URL {
            directory.appendingPathComponent(ext.isEmpty ? "\(stem) \(tag)" : "\(stem) \(tag).\(ext)")
        }
        for number in 2...maxCopyNumber {
            let candidate = tagged(String(number))
            if !exists(candidate) { return candidate }
        }
        return tagged(String(UUID().uuidString.prefix(8)))
    }

    /// Stem and extension (a compound one kept whole; none for a name that is only an extension).
    static func split(_ name: String) -> (stem: String, ext: String) {
        let lowered = name.lowercased()
        if let compound = compoundExtensions.first(where: { lowered.hasSuffix("." + $0.lowercased()) }),
           name.count > compound.count + 1 {
            let stemEnd = name.index(name.endIndex, offsetBy: -(compound.count + 1))
            return (String(name[..<stemEnd]), String(name[name.index(after: stemEnd)...]))
        }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex else {
            return (name, "")
        }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    /// `Content-Disposition: attachment…`: the server wants the response saved, even when WebKit could show it.
    public static func isAttachment(contentDisposition: String?) -> Bool {
        guard let value = contentDisposition?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return value == "attachment" || value.hasPrefix("attachment;") || value.hasPrefix("attachment ")
    }
}

/// How a JavaScript dialog names the page that shows it.
public enum BrowserDialogOrigin {
    /// `example.com`, `127.0.0.1:8000` (a port only when it is not the scheme's default); nil for pages without a host
    /// (files, `about:`, `data:`).
    public static func label(scheme: String, host: String, port: Int) -> String? {
        let scheme = scheme.lowercased()
        guard scheme == "http" || scheme == "https", !host.isEmpty else { return nil }
        let shownHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host  // IPv6
        let defaultPort = scheme == "https" ? 443 : 80
        return port > 0 && port != defaultPort ? "\(shownHost):\(port)" : shownHost
    }
}
