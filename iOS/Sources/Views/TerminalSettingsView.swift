import SwiftUI

/// Terminal text size on this device (⋯ › Settings…). The Mac's terminal size is not changed.
enum TerminalTextSettings {
    static let modeKey = "terminalTextSizeMode"
    static let fontSizeKey = "terminalFontSize"
    static let rememberZoomKey = "terminalRememberPaneZoom"
    private static let paneZoomKey = "terminalPaneZoom"

    static let fontRange: ClosedRange<Double> = 6...24

    enum Mode: String, CaseIterable, Identifiable {
        /// The whole grid width fits the screen (pinch to zoom from there).
        case fit
        /// A fixed font size; wide grids scroll sideways.
        case fixed
        var id: String { rawValue }
    }

    /// Remembered pinch zoom of a pane (multiplier over the base size), when "Remember pinch zoom" is on.
    static func savedZoom(paneID: String) -> CGFloat? {
        guard UserDefaults.standard.bool(forKey: rememberZoomKey),
              let zoom = (UserDefaults.standard.dictionary(forKey: paneZoomKey)?[paneID] as? NSNumber)?.doubleValue,
              zoom > 0 else { return nil }
        return CGFloat(zoom)
    }

    static func saveZoom(_ zoom: CGFloat, paneID: String) {
        guard UserDefaults.standard.bool(forKey: rememberZoomKey) else { return }
        var all = UserDefaults.standard.dictionary(forKey: paneZoomKey) ?? [:]
        if abs(zoom - 1) < 0.01 { all[paneID] = nil } else { all[paneID] = Double(zoom) }
        UserDefaults.standard.set(all, forKey: paneZoomKey)
    }

    static func forgetZooms() {
        UserDefaults.standard.removeObject(forKey: paneZoomKey)
    }
}

struct TerminalSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(TerminalTextSettings.modeKey) private var mode = TerminalTextSettings.Mode.fit
    @AppStorage(TerminalTextSettings.fontSizeKey) private var fontSize = 12.0
    @AppStorage(TerminalTextSettings.rememberZoomKey) private var rememberZoom = false
    @AppStorage(QuickReplies.key) private var quickRepliesStorage = QuickReplies.defaultStorage
    @State private var quickReplies: [QuickReplyRow] = []

    private struct QuickReplyRow: Identifiable {
        let id = UUID()
        var text: String
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Text size", selection: $mode) {
                        Text("Fit to width").tag(TerminalTextSettings.Mode.fit)
                        Text("Fixed size").tag(TerminalTextSettings.Mode.fixed)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("terminalTextSizeMode")
                    if mode == .fixed {
                        VStack(alignment: .leading) {
                            Text("Font size: \(Int(fontSize)) pt")
                            Slider(value: $fontSize, in: TerminalTextSettings.fontRange, step: 1) {
                                Text("Font size")
                            } minimumValueLabel: {
                                Image(systemName: "textformat.size.smaller")
                            } maximumValueLabel: {
                                Image(systemName: "textformat.size.larger")
                            }
                            .accessibilityIdentifier("terminalFontSize")
                            Text(verbatim: "~/project $ git status")
                                .font(.system(size: fontSize, design: .monospaced))
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Terminal text size")
                } footer: {
                    Text(mode == .fit
                         ? "The whole terminal width fits the screen. Pinch to zoom, double-tap to reset."
                         : "Wide terminals scroll sideways. Pinch to zoom, double-tap to reset.")
                }
                Section {
                    Toggle("Remember pinch zoom per pane", isOn: $rememberZoom)
                        .onChange(of: rememberZoom) { _, on in if !on { TerminalTextSettings.forgetZooms() } }
                } footer: {
                    Text("Only changes how this device shows the terminal; the size on the Mac stays the same.")
                }
                quickReplySection
            }
            .onAppear { quickReplies = QuickReplies.decode(quickRepliesStorage).map { QuickReplyRow(text: $0) } }
            .onChange(of: quickReplies.map(\.text)) { _, new in quickRepliesStorage = QuickReplies.encode(new) }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var quickReplySection: some View {
        Section {
            ForEach($quickReplies) { $row in
                TextField("Text to send", text: $row.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .onDelete { quickReplies.remove(atOffsets: $0) }
            .onMove { quickReplies.move(fromOffsets: $0, toOffset: $1) }
            Button("Add Shortcut") { quickReplies.append(QuickReplyRow(text: "")) }
            Button("Restore Defaults") { quickReplies = QuickReplies.defaults.map { QuickReplyRow(text: $0) } }
        } header: {
            HStack {
                Text("Shortcut buttons")
                Spacer()
                EditButton().font(.footnote)
            }
        } footer: {
            Text("Shown above the key bar. Tap one to send its text and Return, for example a reply to an agent or a command such as claude. Long-press to insert it without Return.")
        }
    }
}
