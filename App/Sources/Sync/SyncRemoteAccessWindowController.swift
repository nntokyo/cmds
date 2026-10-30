import AppKit
import CmdsCore

/// "Remote Access via SSH…" window: on/off, relay host (an alias from ~/.ssh/config), relay port and status.
@MainActor
final class SyncRemoteAccessWindowController: NSWindowController {
    static let shared = SyncRemoteAccessWindowController()

    private let access = SyncRemoteAccess.shared
    private let enableCheckbox = NSButton(checkboxWithTitle: String(localized: "Allow remote access via SSH"), target: nil, action: nil)
    private let hostField = NSComboBox()
    private let portField = NSTextField()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let applyButton = NSButton(title: String(localized: "Apply"), target: nil, action: nil)

    private init() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                             styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: true)
        window.title = String(localized: "Remote Access via SSH")
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        super.init(window: window)
        buildContent()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .syncRemoteAccessDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func present() {
        loadFields()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        refresh()
    }

    private func buildContent() {
        let intro = NSTextField(wrappingLabelWithString: String(localized: """
        Lets your paired iPhone or iPad reach this Mac away from home through an SSH server you already use \
        (the relay host). cmds keeps “ssh -R” open to it; the forwarded port listens only on the relay's \
        loopback. The phone logs in to the relay with its own key and opens the forwarded port; the session \
        inside stays end-to-end TLS pinned to this Mac, so the relay sees only ciphertext. Pair on the local \
        network first: pairing codes are not accepted over SSH.
        """))
        intro.preferredMaxLayoutWidth = 400
        intro.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        intro.textColor = .secondaryLabelColor

        hostField.placeholderString = String(localized: "Host from ~/.ssh/config")
        hostField.completes = true
        hostField.usesDataSource = false
        portField.placeholderString = String(SyncRemote.defaultRelayPort)
        statusLabel.preferredMaxLayoutWidth = 400
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        enableCheckbox.target = self
        enableCheckbox.action = #selector(apply(_:))
        applyButton.target = self
        applyButton.action = #selector(apply(_:))
        applyButton.keyEquivalent = "\r"

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "Relay host:")), hostField],
            [NSTextField(labelWithString: String(localized: "Relay port:")), portField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        hostField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        portField.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let hint = NSTextField(wrappingLabelWithString: String(localized: """
        ssh uses your ~/.ssh/config, keys and known_hosts for this host and never prompts (BatchMode). \
        On the phone: Settings › Remote Access, same host, your user name there and this relay port.
        """))
        hint.preferredMaxLayoutWidth = 400
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [enableCheckbox, intro, grid, applyButton, statusLabel, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 440),
        ])
        window?.contentView = content
    }

    private func loadFields() {
        let settings = access.settings
        enableCheckbox.state = settings.enabled ? .on : .off
        hostField.removeAllItems()
        hostField.addItems(withObjectValues: access.configuredHosts)
        hostField.stringValue = settings.host
        portField.stringValue = String(settings.relayPort)
    }

    @objc private func refresh() {
        guard window?.isVisible == true else { return }
        let sync = SyncServer.shared.isEnabled ? "" : "  " + String(localized: "(iOS Sync is off)")
        statusLabel.stringValue = String(localized: "Status: \(access.status.localized)") + sync
    }

    @objc private func apply(_ sender: Any?) {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        let portText = portField.stringValue.trimmingCharacters(in: .whitespaces)
        let port = portText.isEmpty ? SyncRemote.defaultRelayPort : UInt16(portText) ?? 0
        let enabled = enableCheckbox.state == .on
        if enabled, !SyncRemote.isValidHost(host) || port < 1024 {
            NSSound.beep()
            statusLabel.stringValue = !SyncRemote.isValidHost(host)
                ? String(localized: "Enter a host alias from ~/.ssh/config (or user@host).")
                : String(localized: "Use a relay port from 1024 to 65535.")
            if sender as? NSButton === enableCheckbox { enableCheckbox.state = .off }
            return
        }
        access.update(SyncRemote.Settings(enabled: enabled, host: host, relayPort: port))
        refresh()
    }
}
