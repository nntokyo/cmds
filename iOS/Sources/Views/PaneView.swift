import CmdsCore
import SwiftUI
import UIKit

/// One pane: streamed screen, key bar and text input.
struct PaneView: View {
    @Environment(CompanionClient.self) private var client
    let pane: PaneInfo

    var body: some View {
        VStack(spacing: 0) {
            if pane.kind == .preview {
                PreviewFileView(pane: pane)
            } else if pane.kind == .browser {
                ContentUnavailableView {
                    Label(pane.title.isEmpty ? String(localized: "Browser") : DefaultTitle.localized(pane.title), systemImage: "globe")
                } description: {
                    if let url = pane.url { Text(url) }
                }
                if let url = pane.url.flatMap(URL.init(string:)) {
                    Link("Open in Safari", destination: url).padding(.bottom)
                }
            } else {
                TerminalScreenView(paneID: pane.id, snapshot: client.screens[pane.id],
                                   attention: client.needsAttention(pane))
                TerminalInputBar(paneID: pane.id)
            }
        }
    }
}

// MARK: - Screen rendering

struct TerminalScreenView: View {
    @Environment(CompanionClient.self) private var client
    let paneID: String
    let snapshot: ScreenSnapshot?
    let attention: Bool

    /// Multiplier over the base size (fit-to-width or the fixed size from Settings).
    @State private var zoom: CGFloat = 1
    @AppStorage(TerminalTextSettings.modeKey) private var textMode = TerminalTextSettings.Mode.fit
    @AppStorage(TerminalTextSettings.fontSizeKey) private var fixedFontSize = 12.0
    @GestureState private var pinch: CGFloat = 1
    @FocusState private var keyboardFocused: Bool

    /// Focus row vertically centred, line starts at the left edge (centring a long row horizontally would
    /// scroll the start of every line off screen).
    private static let focusAnchor = UnitPoint(x: 0, y: 0.5)
    private static let minFont: CGFloat = 5
    private static let maxFont: CGFloat = 36
    private static let padding: CGFloat = 6
    /// Advance width of one monospaced cell per point of font size.
    private static let cellWidthPerPoint: CGFloat = {
        let font = UIFont.monospacedSystemFont(ofSize: 100, weight: .regular)
        return ("M" as NSString).size(withAttributes: [.font: font]).width / 100
    }()
    private static let lineHeightPerPoint: CGFloat = {
        UIFont.monospacedSystemFont(ofSize: 100, weight: .regular).lineHeight / 100
    }()

    var body: some View {
        GeometryReader { geo in
            if let snapshot, snapshot.cols > 0 {
                let available = geo.size.width - Self.padding * 2
                let base = textMode == .fixed ? CGFloat(fixedFontSize)
                    : available / (CGFloat(snapshot.cols) * Self.cellWidthPerPoint)
                let fontSize = min(Self.maxFont, max(Self.minFont, base * zoom * pinch))
                let cellW = fontSize * Self.cellWidthPerPoint
                let lineH = (fontSize * Self.lineHeightPerPoint).rounded(.up)
                let contentW = CGFloat(snapshot.cols) * cellW
                let contentH = CGFloat(snapshot.rows) * lineH

                ScrollViewReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        screen(snapshot, fontSize: fontSize, cellW: cellW, lineH: lineH)
                            .frame(width: contentW, height: contentH, alignment: .topLeading)
                            .padding(Self.padding)
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: [.horizontal, .vertical])
                    // The terminal grid is usually taller than the phone; follow the cursor (the prompt) instead
                    // of pinning to the bottom, where a mostly empty screen shows only blank rows.
                    .onAppear { proxy.scrollTo(Self.focusRow(snapshot), anchor: Self.focusAnchor) }
                    .onChange(of: snapshot.cursorRow) { proxy.scrollTo(Self.focusRow(snapshot), anchor: Self.focusAnchor) }
                    .onChange(of: fontSize) { proxy.scrollTo(Self.focusRow(snapshot), anchor: Self.focusAnchor) }
                }
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(client.status.isLive ? String(localized: "Waiting for screen…") : client.status.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(white: 0.08))
        .overlay {
            if attention {
                Rectangle().strokeBorder(Color.orange, lineWidth: 2).allowsHitTesting(false)
            }
        }
        .environment(\.colorScheme, .dark)
        .gesture(
            MagnifyGesture()
                .updating($pinch) { value, state, _ in state = value.magnification }
                .onEnded { value in
                    zoom = min(6, max(0.3, zoom * value.magnification))
                    TerminalTextSettings.saveZoom(zoom, paneID: paneID)
                }
        )
        .onTapGesture(count: 2) {
            withAnimation(.snappy) { zoom = 1 }
            TerminalTextSettings.saveZoom(1, paneID: paneID)
        }
        .onAppear { if let saved = TerminalTextSettings.savedZoom(paneID: paneID) { zoom = saved } }
        .onTapGesture { keyboardFocused = true }
        .focusable()
        .focused($keyboardFocused)
        .onKeyPress(phases: [.down, .repeat], action: handleHardwareKey)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Terminal screen")
        .accessibilityIdentifier("terminalScreen")
        .accessibilityValue(snapshot?.lines.joined(separator: "\n") ?? "")
    }

    /// Row to keep in view: the cursor row, else the last non-empty row. Each row view carries its index as
    /// scroll id. (A single zero-content anchor view pushed down with padding did not work: scrollTo left a
    /// zoomed full-screen TUI scrolled to its empty middle rows, i.e. a blank screen.)
    static func focusRow(_ s: ScreenSnapshot) -> Int {
        if let row = s.cursorRow, s.lines.indices.contains(row) { return row }
        return s.lines.lastIndex { !$0.isEmpty } ?? 0
    }

    private func screen(_ s: ScreenSnapshot, fontSize: CGFloat, cellW: CGFloat, lineH: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(s.lines.enumerated()), id: \.offset) { row, line in
                    Text(verbatim: line.isEmpty ? " " : line)
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundStyle(Color(white: 0.92))
                        .lineLimit(1)
                        .fixedSize()
                        .frame(height: lineH, alignment: .leading)
                        .id(row)
                }
            }
            if let row = s.cursorRow, let col = s.cursorCol, row >= 0, row < s.rows {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.65))
                    .frame(width: max(2, cellW), height: lineH)
                    .offset(x: CGFloat(col) * cellW, y: CGFloat(row) * lineH)
                    .allowsHitTesting(false)
            }
        }
    }

    /// iPad / hardware keyboard: forward keys straight to the pane when the screen has focus.
    private func handleHardwareKey(_ press: KeyPress) -> KeyPress.Result {
        let special: [KeyEquivalent: SyncKey] = [
            .return: .enter, .tab: .tab, .escape: .escape, .delete: .backspace, .deleteForward: .delete,
            .upArrow: .up, .downArrow: .down, .leftArrow: .left, .rightArrow: .right,
            .home: .home, .end: .end, .pageUp: .pageUp, .pageDown: .pageDown,
        ]
        if press.modifiers.contains(.command) { return .ignored }
        if let key = special[press.key] {
            client.sendKey(press.key == .tab && press.modifiers.contains(.shift) ? .backTab : key, to: paneID)
            return .handled
        }
        if press.modifiers.contains(.control), let ch = press.key.character.lowercased().first, ch.isLetter {
            client.sendKey(.ctrl(ch), to: paneID)
            return .handled
        }
        guard !press.characters.isEmpty else { return .ignored }
        client.sendText(press.characters, to: paneID)
        return .handled
    }
}

// MARK: - Input

struct TerminalInputBar: View {
    @Environment(CompanionClient.self) private var client
    let paneID: String
    @State private var text = ""
    @State private var ctrlLatched = false
    @State private var directFocused = false
    @FocusState private var lineFieldFocused: Bool
    /// Direct: every keystroke goes to the terminal (the Mac's line editor and cursor are the truth).
    /// Line: compose a whole line locally and send it with Enter.
    @AppStorage("inputMode") private var lineMode = false
    @AppStorage(QuickReplies.key) private var quickReplies = QuickReplies.defaultStorage

    private struct KeyButton: Identifiable {
        /// Also the accessibility identifier (UI test drivers tap keys by it, e.g. `tap:left`).
        let id: String
        let label: String
        /// What VoiceOver reads.
        let spoken: String
        let key: SyncKey
        var systemImage: String?
    }

    private let keys: [KeyButton] = [
        .init(id: "esc", label: "esc", spoken: String(localized: "Escape"), key: .escape),
        .init(id: "tab", label: "tab", spoken: String(localized: "Tab"), key: .tab),
        .init(id: "left", label: "←", spoken: String(localized: "Left"), key: .left, systemImage: "arrow.left"),
        .init(id: "right", label: "→", spoken: String(localized: "Right"), key: .right, systemImage: "arrow.right"),
        .init(id: "up", label: "↑", spoken: String(localized: "Up"), key: .up, systemImage: "arrow.up"),
        .init(id: "down", label: "↓", spoken: String(localized: "Down"), key: .down, systemImage: "arrow.down"),
        .init(id: "home", label: "home", spoken: String(localized: "Home"), key: .home),
        .init(id: "end", label: "end", spoken: String(localized: "End"), key: .end),
        .init(id: "ctrlc", label: "^C", spoken: String(localized: "Control-C"), key: .ctrlC),
        .init(id: "ctrld", label: "^D", spoken: String(localized: "Control-D"), key: .ctrlD),
        .init(id: "bksp", label: "⌫", spoken: String(localized: "Delete"), key: .backspace, systemImage: "delete.left"),
        .init(id: "enter", label: "⏎", spoken: String(localized: "Return"), key: .enter, systemImage: "return"),
    ]

    var body: some View {
        VStack(spacing: 6) {
            let replies = QuickReplies.decode(quickReplies)
            if !replies.isEmpty {
                quickReplyRow(replies)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button {
                        ctrlLatched.toggle()
                    } label: {
                        Text(verbatim: "ctrl").font(.callout.monospaced())
                            .frame(minWidth: 40, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .tint(ctrlLatched ? .accentColor : .secondary)
                    .accessibilityAddTraits(ctrlLatched ? .isSelected : [])

                    ForEach(keys) { k in
                        Button {
                            if lineMode { flushLine() }
                            client.sendKey(k.key, to: paneID)
                            ctrlLatched = false
                        } label: {
                            Group {
                                if let image = k.systemImage { Image(systemName: image) } else { Text(k.label).font(.callout.monospaced()) }
                            }
                            .frame(minWidth: 32, minHeight: 32)
                        }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                        .accessibilityLabel(k.spoken)
                        .accessibilityIdentifier(k.id)
                    }
                }
                .padding(.horizontal, 8)
            }
            HStack(spacing: 8) {
                Button {
                    flushLine()
                    lineMode.toggle()
                    directFocused = !lineMode
                    lineFieldFocused = lineMode
                } label: {
                    Image(systemName: lineMode ? "text.line.first.and.arrowtriangle.forward" : "keyboard")
                        .frame(minWidth: 28, minHeight: 28)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .accessibilityLabel(lineMode ? "Line mode" : "Direct mode")
                .accessibilityHint("Switches between sending each key immediately and sending a whole line")

                if lineMode {
                    lineField
                } else {
                    DirectInputField(
                        placeholder: ctrlLatched ? String(localized: "ctrl + letter") : String(localized: "Keys go straight to the terminal"),
                        ctrlLatched: $ctrlLatched,
                        isFocused: $directFocused,
                        onText: { client.sendText($0, to: paneID) },
                        onKey: { client.sendKey($0, to: paneID) }
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func quickReplyRow(_ replies: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(replies.enumerated()), id: \.offset) { index, reply in
                    Button {
                        sendQuickReply(reply, withEnter: true)
                    } label: {
                        Text(reply).font(.callout).lineLimit(1)
                            .frame(minHeight: 28)
                    }
                    .buttonStyle(.bordered)
                    .tint(.accentColor)
                    .accessibilityHint("Sends this text and Return")
                    .accessibilityIdentifier("quickReply\(index)")
                    .contextMenu {
                        Button("Insert without Enter") { sendQuickReply(reply, withEnter: false) }
                    }
                }
            }
            .padding(.horizontal, 8)
        }
    }

    private var lineField: some View {
        HStack(spacing: 8) {
            TextField(ctrlLatched ? "ctrl + letter" : "Type a line", text: $text)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .focused($lineFieldFocused)
                .onSubmit { send(withEnter: true) }
                .onChange(of: text) { old, new in
                    // With ctrl latched, the next typed letter becomes a control chord.
                    guard ctrlLatched, new.count == old.count + 1, let ch = new.last, ch.isLetter || "@[\\]^_".contains(ch) else { return }
                    client.sendKey(.ctrl(ch), to: paneID)
                    ctrlLatched = false
                    text = old
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Button {
                send(withEnter: true)
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Send")
            .contextMenu {
                Button("Send without Enter") { send(withEnter: false) }
            }
        }
    }

    /// Line mode: a key from the key bar acts on the Mac's line, so send what was typed first.
    private func flushLine() {
        guard !text.isEmpty else { return }
        client.sendText(text, to: paneID)
        text = ""
    }

    /// Line mode: what was typed so far goes first, so a reply can finish a composed line;
    /// without Enter, the reply is added to the line being composed instead.
    private func sendQuickReply(_ reply: String, withEnter: Bool) {
        if lineMode && !withEnter {
            text += reply
            lineFieldFocused = true
            return
        }
        flushLine()
        sendToPane(reply, withEnter: withEnter)
        ctrlLatched = false
    }

    private func send(withEnter: Bool) {
        sendToPane(text, withEnter: withEnter)
        text = ""
        lineFieldFocused = true
    }

    private func sendToPane(_ string: String, withEnter: Bool) {
        client.sendText(string, to: paneID)
        if withEnter { client.sendKey(.enter, to: paneID) }
    }
}

// MARK: - Previews

#Preview("Mock") {
    let client = CompanionClient.live()
    return RootView()
        .environment(client)
        .environment(MacBrowser())
        .onAppear { client.connect(to: .mock) }
}
