import AppKit
import WebKit
import CmdsCore

// `browser.snapshot` with `fullPage`, `selector` and `device(s)` (#169; docs/reference/api.md).
//
// The full page and an element are captured from the pane's own web view without scrolling or resizing it: the
// snapshot rect may lie outside the visible part, WebKit paints the document for it. Other sizes load the pane's URL
// again in a web view of that size in an off-screen window, one size after another, and close it afterwards; that page
// is a fresh load (same cookies and storage, but not the pane's in-page state).
extension BrowserPane {
    /// What the page reports for a capture (CSS pixels, relative to the viewport).
    private struct PageMetrics {
        var viewportWidth: Double
        var viewportHeight: Double
        var scrollX: Double
        var scrollY: Double
        var documentHeight: Double
        /// `getBoundingClientRect()` of the selector's element.
        var element: CGRect?
    }

    func snapshot(_ request: BrowserSnapshotRequest) async throws -> [BrowserSnapshotImage] {
        if request.isPlain {
            let png = try await snapshot()
            let size = emulation.size
            return [BrowserSnapshotImage(device: nil, width: size?.width ?? Int(webView.frame.width / webView.pageZoom),
                                         height: size?.height ?? Int(webView.frame.height / webView.pageZoom), png: png)]
        }
        if request.targets.isEmpty {
            let offscreen = OffscreenRenderHost(hosting: webView)
            defer { offscreen?.release() }
            if offscreen != nil { try await Task.sleep(for: OffscreenRenderHost.paintDelay) }
            return [try await Self.capture(webView, request: request, device: nil)]
        }
        guard let url = webView.url, ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else {
            throw RPCError.invalidParams("the pane shows no web page to capture at other sizes")
        }
        var images: [BrowserSnapshotImage] = []
        for target in request.targets {
            let userAgent = target.preset.map { $0.userAgent } ?? emulation.userAgent
            let capture = CaptureWebView(size: target.size, configuration: webView.configuration,
                                         userAgent: userAgent, appearance: webView.appearance)
            defer { capture.close() }
            try await capture.load(url)
            images.append(try await Self.capture(capture.webView, request: request, device: target.label))
        }
        return images
    }

    /// One image of `webView`: the visible page, the full page or the selector's element.
    private static func capture(_ webView: WKWebView, request: BrowserSnapshotRequest,
                                device: String?) async throws -> BrowserSnapshotImage {
        let metrics = try await pageMetrics(webView, selector: request.selector)
        var rect: CGRect  // CSS pixels, relative to the viewport
        if let element = metrics.element {
            rect = element
        } else if request.fullPage {
            rect = CGRect(x: 0, y: -metrics.scrollY, width: metrics.viewportWidth,
                          height: max(metrics.documentHeight, metrics.viewportHeight))
        } else {
            rect = CGRect(x: 0, y: 0, width: metrics.viewportWidth, height: metrics.viewportHeight)
        }
        rect = rect.integral
        guard rect.width >= 1, rect.height >= 1 else {
            throw RPCError.invalidParams("the element matching \(request.selector ?? "") has no size (hidden?)")
        }
        guard Int(rect.height) <= BrowserSnapshotRequest.maxHeight else {
            throw BrowserSnapshotRequest.tooTall(Int(rect.height))
        }
        guard Int(rect.width) <= BrowserSnapshotRequest.maxHeight else {
            throw RPCError.invalidParams("the capture is \(Int(rect.width)) CSS pixels wide, over the \(BrowserSnapshotRequest.maxHeight) px limit")
        }
        let zoom = webView.pageZoom
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom,
                                    height: rect.height * zoom)
        // Output in points × the window's backing scale: CSS pixels at 2× (1× for very tall captures).
        let backing = webView.window?.backingScaleFactor ?? 2
        let scale = BrowserSnapshotRequest.outputScale(cssHeight: rect.height)
        configuration.snapshotWidth = NSNumber(value: Double(rect.width) * scale / backing)
        configuration.afterScreenUpdates = true
        let png: Data
        if request.fullPage || metrics.element != nil {
            // takeSnapshot paints only what is on screen (the rest comes out blank); WebKit's PDF of the view covers
            // the whole document, so parts below the fold come from it.
            let pdf = WKPDFConfiguration()
            if metrics.element != nil { pdf.rect = configuration.rect }
            png = try pngFromPDF(try await webView.pdf(configuration: pdf), scale: scale / zoom)
        } else {
            png = try await Self.png(of: webView, configuration: configuration)
        }
        return BrowserSnapshotImage(device: device, width: Int(rect.width), height: Int(rect.height), png: png)
    }

    /// The first page of `data` (WebKit's PDF of the view, one page of the captured size in view points) as a PNG with
    /// `scale` pixels per point, on white (the page's own background is drawn over it).
    private static func pngFromPDF(_ data: Data, scale: Double) throws -> Data {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { throw RPCError(code: 500, message: "WebKit returned no page") }
        let box = page.getBoxRect(.mediaBox)
        let width = Int((box.width * scale).rounded()), height = Int((box.height * scale).rounded())
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RPCError(code: 500, message: "cannot draw a \(width)×\(height) image")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw RPCError(code: 500, message: "PNG encoding failed")
        }
        return png
    }

    /// Viewport, scroll position, document height and the element's rect, read in cmds' own script world.
    private static func pageMetrics(_ webView: WKWebView, selector: String?) async throws -> PageMetrics {
        let script = """
            const doc = document.documentElement, body = document.body;
            const result = { vw: window.innerWidth, vh: window.innerHeight, sx: window.scrollX, sy: window.scrollY,
              dh: Math.max(doc ? doc.scrollHeight : 0, body ? body.scrollHeight : 0) };
            if (selector !== null) {
              let element;
              try { element = document.querySelector(selector); } catch (e) { return { invalidSelector: String(e.message) }; }
              if (!element) return { noElement: true };
              const r = element.getBoundingClientRect();
              result.element = [r.left, r.top, r.width, r.height];
            }
            return result;
            """
        let raw = try await webView.callAsyncJavaScript(script, arguments: ["selector": selector ?? NSNull()], in: nil,
                                                        contentWorld: .defaultClient)
        guard let object = raw as? [String: Any] else { throw RPCError(code: 500, message: "could not measure the page") }
        if let message = object["invalidSelector"] as? String {
            throw RPCError.invalidParams("invalid selector \(selector ?? ""): \(message)")
        }
        if object["noElement"] != nil { throw RPCError.notFound("no element matches \(selector ?? "")") }
        func number(_ key: String) -> Double { (object[key] as? NSNumber)?.doubleValue ?? 0 }
        var element: CGRect?
        if let values = object["element"] as? [NSNumber], values.count == 4 {
            element = CGRect(x: values[0].doubleValue, y: values[1].doubleValue, width: values[2].doubleValue,
                             height: values[3].doubleValue)
        }
        return PageMetrics(viewportWidth: number("vw"), viewportHeight: number("vh"), scrollX: number("sx"),
                           scrollY: number("sy"), documentHeight: number("dh"), element: element)
    }
}

/// A web view of a device size in a borderless window outside the screen, for one capture. Shares the pane's
/// configuration (website data, so the same cookies), and its user agent and appearance.
@MainActor
private final class CaptureWebView: NSObject, WKNavigationDelegate {
    /// How long a page may take to load.
    static let loadTimeout: Duration = .seconds(30)
    /// Time WebKit gets to lay out and paint after the load (web fonts, late layout).
    static let settleDelay: Duration = .milliseconds(600)

    let webView: WKWebView
    private let window: NSWindow
    private var loadContinuation: CheckedContinuation<Void, Error>?

    init(size: ViewportSize, configuration: WKWebViewConfiguration, userAgent: String?, appearance: NSAppearance?) {
        let frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        webView = WKWebView(frame: frame, configuration: configuration)
        webView.customUserAgent = userAgent
        webView.appearance = appearance
        window = RenderOnlyWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: frame.size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
        window.orderFrontRegardless()
    }

    func load(_ url: URL) async throws {
        let timeout = Task { @MainActor [weak self] in
            try await Task.sleep(for: Self.loadTimeout)
            self?.finish(.failure(RPCError(code: 500, message: "\(url.absoluteString.prefix(200)) did not load within \(Self.loadTimeout.components.seconds) s")))
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            webView.load(URLRequest(url: url))
        }
        try await Task.sleep(for: Self.settleDelay)
    }

    func close() {
        finish(.failure(CancellationError()))
        webView.navigationDelegate = nil
        webView.stopLoading()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(RPCError(code: 500, message: "the page did not load: \(error.localizedDescription)")))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(RPCError(code: 500, message: "the page did not load: \(error.localizedDescription)")))
    }
}
