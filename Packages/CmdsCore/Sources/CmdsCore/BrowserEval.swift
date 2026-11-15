import Foundation

/// `browser.eval`'s deadline (#338): a script still running after `timeout` seconds gets an error instead of a reply
/// that never comes (`while (true) {}`, a promise that never settles). A page that no longer answers at all (its
/// script never yields) is loaded again in a new web view, so the pane works again.
public enum BrowserEval {
    public static let defaultTimeout: Double = 30
    public static let maxTimeout: Double = 300
    /// How much longer than the timeout a client waits for the reply (a stuck page is replaced before it).
    public static let clientMargin: Double = 30

    /// The `timeout` param in seconds (default 30, more than 0, at most 300).
    public static func timeout(params: JSONValue?) throws -> Double {
        switch params?["timeout"] {
        case nil, .null?: return defaultTimeout
        case .number(let value)? where value > 0 && value <= maxTimeout: return value
        default: throw RPCError.invalidParams("timeout must be more than 0 and at most \(Int(maxTimeout)) seconds")
        }
    }

    /// The 408 error's text: the script did not finish; `reloaded`: its page did not answer and was loaded again.
    public static func timeoutMessage(seconds: Double, reloaded: Bool) -> String {
        let text = "the script did not finish in \(format(seconds)) s"
        return reloaded ? text + "; the page stopped responding and was reloaded" : text
    }

    /// `5`, `2.5`.
    public static func format(_ seconds: Double) -> String {
        seconds.rounded() == seconds ? String(Int(seconds)) : String(format: "%.1f", seconds)
    }
}

/// English text of WebKit, URL loading and other system errors for API and CLI replies: an `NSError`'s
/// `localizedDescription` is in the app's language, and API messages stay English (docs/internals/localization.md,
/// #338).
public enum EnglishErrorText {
    public static let webKitDomain = "WKErrorDomain"

    /// The text of an error of a system framework (with the file it is about); nil for other domains (the app's own
    /// errors, whose descriptions are English already).
    public static func message(domain: String, code: Int, path: String? = nil) -> String? {
        let text: String
        switch domain {
        case webKitDomain:
            text = webKit[code] ?? "WebKit error \(code)"
        case NSURLErrorDomain:
            text = urlLoading[code] ?? "URL loading error \(code)"
        case NSPOSIXErrorDomain:
            text = String(cString: strerror(Int32(truncatingIfNeeded: code)))
        case NSCocoaErrorDomain, NSOSStatusErrorDomain, NSMachErrorDomain, "kCFErrorDomainCFNetwork":
            text = "\(domain) error \(code)"
        default:
            return nil
        }
        return path.map { "\(text): \($0)" } ?? text
    }

    /// `WKError.Code`.
    static let webKit: [Int: String] = [
        1: "an unknown WebKit error occurred",
        2: "the page's web content process ended",
        3: "the web view was closed",
        4: "a JavaScript exception occurred",
        5: "the script's result is not a JSON-compatible value (return a string, number, boolean, array, object or null)",
        6: "compiling the content rule list failed",
        7: "the content rule list was not found",
        8: "removing the content rule list failed",
        9: "the content rule list has an unsupported version",
        10: "the content did not load",
        11: "loading the content timed out",
        12: "the frame to run the script in is gone",
        13: "the navigation is outside the app-bound domains",
        14: "the script is outside the app-bound domains",
        15: "a credential with this ID exists already",
        16: "the credential is malformed",
        17: "the credential was not found",
    ]

    /// `URLError.Code`.
    static let urlLoading: [Int: String] = [
        NSURLErrorCancelled: "the load was cancelled",
        NSURLErrorBadURL: "the URL is not valid",
        NSURLErrorTimedOut: "the request timed out",
        NSURLErrorUnsupportedURL: "the URL is not supported",
        NSURLErrorCannotFindHost: "the server was not found",
        NSURLErrorCannotConnectToHost: "could not connect to the server",
        NSURLErrorNetworkConnectionLost: "the network connection was lost",
        NSURLErrorDNSLookupFailed: "the DNS lookup failed",
        NSURLErrorHTTPTooManyRedirects: "too many redirects",
        NSURLErrorResourceUnavailable: "the resource is unavailable",
        NSURLErrorNotConnectedToInternet: "not connected to the internet",
        NSURLErrorBadServerResponse: "the server sent a bad response",
        NSURLErrorUserAuthenticationRequired: "authentication is required",
        NSURLErrorZeroByteResource: "the server sent no data",
        NSURLErrorAppTransportSecurityRequiresSecureConnection: "App Transport Security requires a secure connection",
        NSURLErrorFileDoesNotExist: "the file does not exist",
        NSURLErrorFileIsDirectory: "the file is a folder",
        NSURLErrorNoPermissionsToReadFile: "no permission to read the file",
        NSURLErrorSecureConnectionFailed: "a secure (TLS) connection could not be made",
        NSURLErrorServerCertificateHasBadDate: "the server's certificate has expired or is not yet valid",
        NSURLErrorServerCertificateUntrusted: "the server's certificate is not trusted",
        NSURLErrorServerCertificateHasUnknownRoot: "the server's certificate has an unknown root",
        NSURLErrorServerCertificateNotYetValid: "the server's certificate is not yet valid",
        NSURLErrorClientCertificateRejected: "the client certificate was rejected",
        NSURLErrorClientCertificateRequired: "a client certificate is required",
    ]
}
