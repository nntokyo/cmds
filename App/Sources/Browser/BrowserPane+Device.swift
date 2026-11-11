import AppKit
import WebKit
import CmdsCore

// Device sizes, user agent and color scheme of a browser pane (#168; docs/guide/workspaces-and-panes.md "Device sizes").
//
// A device size gives the web view exactly that size in points, so the page's CSS viewport is the device's
// (innerWidth, media queries) and devicePixelRatio stays the Mac's; the host view's coordinates are scaled so it fits
// the pane. (Page zoom would also fit it, but WebKit then rounds the layout width and scales devicePixelRatio.)
// WKWebView has no public way to emulate the pixel ratio, touch, `<meta viewport>` or reduced motion; the menu says so.
extension BrowserPane {
    /// Space around a device-sized page.
    static let deviceMargin: CGFloat = 8
    /// How long the breakpoint indicator waits for layout and loading to settle before reading the page.
    static let breakpointRefreshDelay: TimeInterval = 0.25
    /// What Custom Size… offers while the page fills the pane (iPhone SE).
    static let defaultCustomSize = ViewportSize(width: 375, height: 667)

    /// The scale the page is shown at (1 when it fills the pane or fits unscaled).
    var deviceScale: Double {
        guard let size = emulation.size else { return 1 }
        let area = NSRect(origin: .zero, size: viewportHost.frame.size).insetBy(dx: Self.deviceMargin, dy: Self.deviceMargin)
        return size.scaleToFit(width: area.width, height: area.height)
    }

    func startEmulation() {
        viewportHost.onLayout = { [weak self] in self?.layoutWebView() }
        webView.customUserAgent = emulation.userAgent
        applyColorScheme()
        updateDeviceButton()
    }

    /// Applies `change` (API and menu); returns the new settings.
    @discardableResult
    func apply(_ change: BrowserViewportChange) throws -> BrowserEmulation {
        setEmulation(try change.applied(to: emulation))
        return emulation
    }

    func setEmulation(_ new: BrowserEmulation) {
        let old = emulation
        guard new != old else { return }
        emulation = new
        // In the responsive view the frames send their devices' user agents; this one applies when it ends.
        if new.userAgent != old.userAgent, responsiveView == nil { webView.setUserAgent(new.userAgent) }
        if new.scheme != old.scheme { applyColorScheme() }
        if new.size != old.size { layoutWebView() }
        updateDeviceButton()
        scheduleBreakpointRefresh()
        onEmulationChange?()
    }

    /// The page fills the host, or sits centered at its device size scaled to fit.
    func layoutWebView() {
        guard responsiveView == nil else { return }  // the web view is a frame of the responsive view
        let frame = viewportHost.frame
        guard let size = emulation.size else {
            viewportHost.scale(to: 1)
            webView.frame = viewportHost.bounds
            if webView.pageZoom != fillZoom { webView.pageZoom = fillZoom }
            scheduleBreakpointRefresh()
            return
        }
        guard frame.width >= 1, frame.height >= 1 else { return }
        // The view keeps the device size (so the page's CSS pixels are WebKit's points: innerWidth and
        // devicePixelRatio stay exact); the host's coordinates are scaled so it fits.
        let scale = deviceScale
        viewportHost.scale(to: scale)
        let bounds = viewportHost.bounds
        let width = CGFloat(size.width), height = CGFloat(size.height)
        webView.frame = NSRect(x: ((bounds.width - width) / 2).rounded(.down), y: Self.deviceMargin / scale,
                               width: width, height: height)
        if webView.pageZoom != 1 { webView.pageZoom = 1 }
        scheduleBreakpointRefresh()
    }

    /// The page's `prefers-color-scheme` follows the web view's appearance; `system` is the Mac's setting (the main
    /// window itself is always dark).
    func applyColorScheme() {
        let dark: Bool
        switch emulation.scheme {
        case .light: dark = false
        case .dark: dark = true
        case .system: dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if webView.appearance?.name != appearance?.name { webView.appearance = appearance }
        responsiveView?.setAppearance(appearance)
    }

    // MARK: - Toolbar

    func buildDeviceControls() {
        breakpointLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        breakpointLabel.textColor = .secondaryLabelColor
        breakpointLabel.lineBreakMode = .byTruncatingTail
        breakpointLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        breakpointLabel.setContentHuggingPriority(.required, for: .horizontal)
        deviceButton.target = self
        deviceButton.action = #selector(deviceButtonClicked(_:))
    }

    func updateDeviceButton() {
        deviceButton.contentTintColor = emulation.isDefault && responsiveView == nil ? nil : .controlAccentColor
        var tip = String(localized: "Device Size")
        if let responsive {
            tip += " — " + String(localized: "Responsive View") + " (\(responsive.devices.joined(separator: ", ")))"
        } else if let sizeName = emulation.sizeName {
            tip += " — " + sizeName
        }
        deviceButton.toolTip = tip
    }

    func scheduleBreakpointRefresh() {
        breakpointRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refreshBreakpoints() }
        }
        breakpointRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.breakpointRefreshDelay, execute: item)
    }

    /// Reads the CSS width and the media queries of the page (in cmds' own script world, so the page's scripts do not
    /// see it) and shows `375 px · <640 · 80%`.
    private func refreshBreakpoints() {
        if let responsiveView {  // the frames' widths
            breakpointLabel.stringValue = responsiveView.targets.map { "\($0.size.width)" }.joined(separator: " · ") + " px"
            breakpointLabel.toolTip = String(localized: "Responsive View")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = try? await webView.callAsyncJavaScript(Breakpoints.pageScript, arguments: [:], in: nil,
                                                                 contentWorld: .defaultClient)
            guard let object = result as? [String: Any], let width = (object["width"] as? NSNumber)?.intValue,
                  webView.url?.scheme != "about", webView.url != nil else {
                breakpointLabel.stringValue = ""
                breakpointLabel.toolTip = nil
                return
            }
            let thresholds = Breakpoints.thresholds(fromMediaQueries: object["queries"] as? [String] ?? [])
            var parts = ["\(width) px"]
            if let range = Breakpoints.label(width: width, thresholds: thresholds) { parts.append(range) }
            let scale = deviceScale
            if emulation.size != nil, scale < 0.995 { parts.append("\(Int((scale * 100).rounded()))%") }
            breakpointLabel.stringValue = parts.joined(separator: " · ")
            var tip = String(localized: "CSS width of the page and the range of its media-query breakpoints it is in.")
            tip += "\n" + (thresholds.isEmpty ? String(localized: "No width breakpoints found in the page's style sheets.")
                : String(localized: "Breakpoints: \(thresholds.map(String.init).joined(separator: ", ")) px"))
            breakpointLabel.toolTip = tip
        }
    }

    // MARK: - Menu

    @objc private func deviceButtonClicked(_ sender: NSButton) {
        onFocus?()
        deviceMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    func deviceMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, _ action: Selector?, on: Bool = false, enabled: Bool = true, object: Any? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = on ? .on : .off
            item.isEnabled = enabled
            item.representedObject = object
            return item
        }
        menu.addItem(item(String(localized: "Fill Pane"), #selector(fillPaneChosen), on: emulation.size == nil))
        let headers: [DevicePreset.Category: String] = [
            .phone: String(localized: "Phones"), .tablet: String(localized: "Tablets"), .desktop: String(localized: "Desktops"),
        ]
        for category in DevicePreset.Category.allCases {
            menu.addItem(.sectionHeader(title: headers[category] ?? category.rawValue))
            for preset in DevicePreset.all where preset.category == category {
                menu.addItem(item("\(preset.name)  \(preset.size.description)", #selector(presetChosen(_:)),
                                  on: emulation.device == preset.id, object: preset.id))
            }
        }
        menu.addItem(.separator())
        let custom = emulation.size.flatMap { emulation.device == nil ? $0 : nil }
        menu.addItem(item(custom.map { String(localized: "Custom Size (\($0.description))…") } ?? String(localized: "Custom Size…"),
                          #selector(customSizeChosen), on: custom != nil))
        menu.addItem(item(String(localized: "Rotate"), #selector(rotateChosen), enabled: emulation.size != nil))
        menu.addItem(.separator())
        let responsiveTitle = String(localized: "Responsive View (Phone, Tablet, Desktop)")
        menu.addItem(item(responsive.map { _ in String(localized: "Responsive View") } ?? responsiveTitle,
                          #selector(responsiveViewChosen), on: responsive != nil))
        menu.addItem(item(String(localized: "Sync Scrolling"), #selector(syncScrollingChosen),
                          on: responsive?.scrollSynced == true, enabled: responsive != nil))
        menu.addItem(.separator())

        let schemes = NSMenu()
        for (scheme, title) in [(BrowserColorScheme.system, String(localized: "Follow the Mac")),
                                (.light, String(localized: "Light")), (.dark, String(localized: "Dark"))] {
            schemes.addItem(item(title, #selector(colorSchemeChosen(_:)), on: emulation.scheme == scheme, object: scheme.rawValue))
        }
        let schemeItem = NSMenuItem(title: String(localized: "Color Scheme"), action: nil, keyEquivalent: "")
        schemeItem.submenu = schemes
        menu.addItem(schemeItem)

        let agents = NSMenu()
        agents.addItem(item(String(localized: "WebKit Default"), #selector(userAgentChosen(_:)), on: emulation.userAgent == nil,
                            object: ""))
        for agent in DevicePreset.userAgents {
            agents.addItem(item(BrowserEmulation.userAgentName(agent), #selector(userAgentChosen(_:)),
                                on: emulation.userAgent == agent, object: agent))
        }
        let customAgent = emulation.userAgent.flatMap { DevicePreset.userAgents.contains($0) ? nil : $0 }
        agents.addItem(item(String(localized: "Custom…"), #selector(customUserAgentChosen), on: customAgent != nil))
        let agentItem = NSMenuItem(title: String(localized: "User Agent"), action: nil, keyEquivalent: "")
        agentItem.submenu = agents
        menu.addItem(agentItem)

        menu.addItem(.separator())
        let limits = item(String(localized: "Not emulated: pixel ratio, touch, <meta viewport>, reduced motion"),
                          nil, enabled: false)
        limits.toolTip = String(localized: "WebKit on the Mac sets the layout size, user agent and color scheme only. Check pixel density, touch input, pointer: coarse, <meta name=\"viewport\"> scaling and prefers-reduced-motion on a real device.")
        menu.addItem(limits)
        return menu
    }

    private func change(_ change: BrowserViewportChange) {
        do {
            try apply(change)
        } catch {
            NSSound.beep()
        }
    }

    @objc private func fillPaneChosen() { change(BrowserViewportChange(size: .fill)) }
    @objc private func rotateChosen() { change(BrowserViewportChange(rotate: true)) }

    @objc private func presetChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let preset = DevicePreset.named(id) else { return }
        change(BrowserViewportChange(size: .preset(preset)))
    }

    @objc private func colorSchemeChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let scheme = BrowserColorScheme(rawValue: raw) else { return }
        change(BrowserViewportChange(colorScheme: scheme))
    }

    @objc private func userAgentChosen(_ sender: NSMenuItem) {
        guard let agent = sender.representedObject as? String else { return }
        change(BrowserViewportChange(userAgent: agent))
    }

    @objc private func customSizeChosen() {
        let current = emulation.size ?? Self.defaultCustomSize
        let width = NSTextField(string: String(current.width)), height = NSTextField(string: String(current.height))
        let times = NSTextField(labelWithString: "×")
        let row = NSStackView(views: [width, times, height])
        row.spacing = 6
        row.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        width.widthAnchor.constraint(equalToConstant: 80).isActive = true
        height.widthAnchor.constraint(equalToConstant: 80).isActive = true
        prompt(title: String(localized: "Custom Size"),
               message: String(localized: "Width and height in CSS pixels (\(ViewportSize.range.lowerBound)–\(ViewportSize.range.upperBound))."),
               accessory: row, focus: width) { [weak self] in
            guard let w = Int(width.stringValue.trimmingCharacters(in: .whitespaces)),
                  let h = Int(height.stringValue.trimmingCharacters(in: .whitespaces)) else { NSSound.beep(); return }
            let size = ViewportSize(width: w, height: h)
            guard (try? size.validate()) != nil else { NSSound.beep(); return }
            self?.change(BrowserViewportChange(size: .custom(size)))
        }
    }

    @objc private func customUserAgentChosen() {
        let field = NSTextField(string: emulation.userAgent ?? "")
        field.placeholderString = String(localized: "WebKit Default")
        field.frame = NSRect(x: 0, y: 0, width: 420, height: 24)
        prompt(title: String(localized: "Custom User Agent"),
               message: String(localized: "Sent with every request of this pane. Leave empty for WebKit's own."),
               accessory: field, focus: field) { [weak self] in
            guard let agent = try? BrowserEmulation.checkedUserAgent(field.stringValue) else { NSSound.beep(); return }
            self?.change(BrowserViewportChange(userAgent: agent ?? ""))
        }
    }

    private func prompt(title: String, message: String, accessory: NSView, focus: NSView, onOK: @escaping () -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = focus
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { if response == .alertFirstButtonReturn { onOK() } }
        }
    }
}

#if DEBUG
extension BrowserPane {
    /// `debug.browser`: the indicator, the web view's frame in the pane, the scale, and the pane drawn without its page;
    /// the download notice, pop-ups and dialogs, `answer` / `text` answering the dialog (`BrowserPageDelegate`).
    func debugState(answer: String?, text: String?) -> JSONValue {
        let frame = convert(webView.frame, from: viewportHost)
        var result: [String: JSONValue] = [
            "indicator": .string(breakpointLabel.stringValue),
            "indicatorShown": .bool(breakpointLabel.superview != nil && !breakpointLabel.isHidden),
            "indicatorToolTip": .string(breakpointLabel.toolTip ?? ""),
            "webViewFrame": .array([frame.minX, frame.minY, frame.width, frame.height].map { .number(Double($0)) }),
            "webViewSize": .array([webView.frame.width, webView.frame.height].map { .number(Double($0)) }),
            "scale": .number(deviceScale),
            "pageZoom": .number(webView.pageZoom),
            "appearance": .string(webView.appearance?.name.rawValue ?? ""),
            "menu": .array(deviceMenu().items.map { .string(($0.state == .on ? "✓ " : "") + $0.title) }),
            "responsive": responsiveView?.debugFrames ?? .null,
            "download": downloadNoticeText.map { .string($0) } ?? .null,
            "watch": watchJSON, "watchReloads": .number(Double(watchReloadCount)),
            "watchPaths": .array(watchCountedPaths.map { .string($0) }),
            "watchMenu": .array(watchMenu().items.map { .string(($0.state == .on ? "✓ " : "") + $0.title) }),
            "watchToolTip": .string(watchButton.toolTip ?? ""),
        ]
        result.merge(pageDelegate.debugState(answer: answer, text: text)) { _, new in new }  // pop-ups and dialogs (#235)
        if let bitmap = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                result["png_base64"] = .string(png.base64EncodedString())
            }
        }
        return .object(result)
    }
}
#endif

/// The area below the browser toolbar; lays out the web view itself (fill or device size).
final class ViewportHostView: NSView {
    var onLayout: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        onLayout?()
    }

    /// Scales the coordinate system so that `1 / scale` points fit in each point of the frame.
    func scale(to scale: Double) {
        let size = NSSize(width: frame.width / scale, height: frame.height / scale)
        if bounds.size != size { setBoundsSize(size) }
    }
}
