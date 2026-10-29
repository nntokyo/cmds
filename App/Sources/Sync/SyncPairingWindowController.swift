import AppKit
import CmdsCore
import CoreImage.CIFilterBuiltins

/// "Pair iPhone/iPad…" window: pairing QR code and code, the Mac's identity (short fingerprint), Mac
/// name, connection status, paired and connected devices, plus the "Enable iOS Sync" toggle,
/// "Revoke All Devices" and "Reset Sync Identity".
@MainActor
final class SyncPairingWindowController: NSWindowController {
    static let shared = SyncPairingWindowController()

    private static let qrSide: CGFloat = 176

    private let server = SyncServer.shared
    private let enableCheckbox = NSButton(checkboxWithTitle: "Enable iOS Sync", target: nil, action: nil)
    private let qrView = NSImageView()
    private let codeLabel = NSTextField(labelWithString: "")
    private let identityLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let devicesLabel = NSTextField(wrappingLabelWithString: "")
    private let newCodeButton = NSButton(title: "New Code", target: nil, action: nil)
    private let revokeButton = NSButton(title: "Revoke All Devices…", target: nil, action: nil)
    private let resetIdentityButton = NSButton(title: "Reset Sync Identity…", target: nil, action: nil)
    private var countdown: Timer?
    /// Payload the QR image was rendered for.
    private var qrPayload: String?

    private init() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
                             styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: true)
        window.title = "Pair iPhone/iPad"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        NotificationCenter.default.addObserver(self, selector: #selector(serverDidChange), name: .syncServerDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func present() {
        // Pairing codes are accepted only while this window is open.
        server.isPairingOpen = true
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        refresh()
        startCountdown()
    }

    private func buildContent() {
        let title = NSTextField(labelWithString:
            "In cmds on your iPhone or iPad, tap Scan Pairing Code and point it at this QR code. "
            + "Without a camera: pick this Mac, check that the identity matches, and enter the code.")
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 0
        title.preferredMaxLayoutWidth = 340

        // Rendered at whole pixels per module; scaling it again would blur the modules.
        qrView.imageScaling = .scaleNone
        qrView.setAccessibilityLabel("Pairing QR code")
        qrView.translatesAutoresizingMaskIntoConstraints = false

        codeLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        codeLabel.isSelectable = true
        codeLabel.alignment = .center

        identityLabel.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        identityLabel.isSelectable = true
        identityLabel.alignment = .center

        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.preferredMaxLayoutWidth = 340
        devicesLabel.preferredMaxLayoutWidth = 340

        enableCheckbox.target = self
        enableCheckbox.action = #selector(toggleEnabled(_:))
        newCodeButton.target = self
        newCodeButton.action = #selector(newCode(_:))
        revokeButton.target = self
        revokeButton.action = #selector(revokeAll(_:))
        resetIdentityButton.target = self
        resetIdentityButton.action = #selector(resetIdentity(_:))

        let buttons = NSStackView(views: [newCodeButton, revokeButton])
        buttons.orientation = .horizontal
        let devicesHeader = NSTextField(labelWithString: "Devices")
        devicesHeader.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let stack = NSStackView(views: [enableCheckbox, title, qrView, codeLabel, identityLabel, detailLabel,
                                        devicesHeader, devicesLabel, buttons, resetIdentityButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.setCustomSpacing(4, after: codeLabel)
        stack.setCustomSpacing(16, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        codeLabel.translatesAutoresizingMaskIntoConstraints = false
        identityLabel.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 380),
            qrView.widthAnchor.constraint(equalToConstant: Self.qrSide),
            qrView.heightAnchor.constraint(equalToConstant: Self.qrSide),
            qrView.centerXAnchor.constraint(equalTo: stack.centerXAnchor),
            codeLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            identityLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        window?.contentView = content
    }

    @objc private func serverDidChange() { refresh() }

    private func refresh() {
        guard window?.isVisible == true else { return }
        let enabled = server.isEnabled
        enableCheckbox.state = enabled ? .on : .off
        newCodeButton.isEnabled = enabled
        revokeButton.isEnabled = !server.store.devices.isEmpty

        let payload = enabled ? server.pairingPayload : nil
        updateQRCode(payload?.uri)
        if let fingerprint = server.identity?.fingerprint {
            identityLabel.stringValue = "Mac identity: \(fingerprint.short)"
            identityLabel.toolTip = "SHA-256 \(fingerprint.hex)"
        } else {
            identityLabel.stringValue = "Mac identity: –"
            identityLabel.toolTip = nil
        }

        if enabled {
            let code = server.pairingCode
            codeLabel.stringValue = "\(code.prefix(3)) \(code.suffix(3))"
            codeLabel.textColor = .labelColor
            let remaining = max(0, Int(server.codeExpiresAt.timeIntervalSinceNow))
            let address = payload.map { "\($0.host):\($0.port)" } ?? "–"
            detailLabel.stringValue = """
            Mac: \(server.macName)   •   \(server.statusText)   •   \(address)
            The code is valid only while this window is open; it changes in \(remaining / 60):\(String(format: "%02d", remaining % 60)) and after each pairing.
            Encrypted (TLS 1.3). Your iPhone or iPad trusts only this Mac's identity.
            """
        } else {
            codeLabel.stringValue = "––– –––"
            codeLabel.textColor = .tertiaryLabelColor
            detailLabel.stringValue = "Mac: \(server.macName)   •   iOS Sync is off"
        }

        let connected = server.connectedDevices
        var lines: [String] = server.store.devices.map { device in
            let hosts = connected.filter { SyncDeviceStore.digestsEqual($0.tokenHash, device.tokenHash) }.map(\.host)
            let state = hosts.isEmpty
                ? (device.lastSeen.map { "last seen " + Self.relative($0) } ?? "not connected")
                : "connected (\(Set(hosts).sorted().joined(separator: ", ")))"
            return "• \(device.name) — \(state)"
        }
        if lines.isEmpty { lines = ["No paired devices."] }
        devicesLabel.stringValue = lines.joined(separator: "\n")
    }

    /// Re-renders the QR code when its payload changed (the code rotates, the address changes).
    private func updateQRCode(_ payload: String?) {
        guard payload != qrPayload else { return }
        qrPayload = payload
        qrView.image = payload.flatMap { Self.qrImage($0, side: Self.qrSide) }
        qrView.alphaValue = payload == nil ? 0.2 : 1
    }

    /// Black-on-white QR code with a 4-module quiet zone, crisp at 2x.
    static func qrImage(_ text: String, side: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        let modules = code.extent.width + 8
        let scale = max(1, floor(side * 2 / modules))
        let pixels = modules * scale
        let placed = code.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: 4 * scale, y: 4 * scale))
        let canvas = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        let image = placed.composited(over: CIImage(color: .white).cropped(to: canvas))
        guard let cgImage = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(image, from: canvas) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: pixels / 2, height: pixels / 2))
    }

    private func startCountdown() {
        guard countdown == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.window?.isVisible != true {
                    self.countdown?.invalidate()
                    self.countdown = nil
                    return
                }
                self.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdown = timer
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    @objc private func toggleEnabled(_ sender: NSButton) {
        server.isEnabled = sender.state == .on
        refresh()
    }

    @objc private func newCode(_ sender: Any?) {
        server.rotateCode()
    }

    @objc private func revokeAll(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Revoke all paired devices?"
        alert.informativeText = "Every iPhone and iPad will be disconnected and must be paired again with a new code."
        alert.addButton(withTitle: "Revoke All")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                self?.server.revokeAllDevices()
                self?.refresh()
            }
        }
    }

    @objc private func resetIdentity(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Reset this Mac's sync identity?"
        alert.informativeText = """
        cmds creates a new key and certificate for iOS Sync and unpairs every iPhone and iPad. \
        Each one must be paired again; until then they report that this Mac's identity changed.
        """
        alert.addButton(withTitle: "Reset Identity")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                self?.server.resetIdentity()
                self?.refresh()
            }
        }
    }
}

extension SyncPairingWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        server.isPairingOpen = false
        countdown?.invalidate()
        countdown = nil
    }
}

/// Target for the sync items in the app menu ("Pair iPhone/iPad…", "Enable iOS Sync").
@MainActor
final class SyncMenuActions: NSObject, NSMenuItemValidation {
    static let shared = SyncMenuActions()

    static func items() -> [NSMenuItem] {
        let pair = NSMenuItem(title: "Pair iPhone/iPad…", action: #selector(showPairing(_:)), keyEquivalent: "")
        let toggle = NSMenuItem(title: "Enable iOS Sync", action: #selector(toggleSync(_:)), keyEquivalent: "")
        for item in [pair, toggle] { item.target = shared }
        return [pair, toggle]
    }

    @objc func showPairing(_ sender: Any?) {
        SyncPairingWindowController.shared.present()
    }

    @objc func toggleSync(_ sender: Any?) {
        SyncServer.shared.isEnabled.toggle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSync(_:)) {
            menuItem.state = SyncServer.shared.isEnabled ? .on : .off
        }
        return true
    }
}
