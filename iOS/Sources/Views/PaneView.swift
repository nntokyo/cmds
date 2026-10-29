import CmdsCore
import SwiftUI
import UIKit

/// One pane: streamed screen, key bar and text input.
struct PaneView: View {
    @Environment(CompanionClient.self) private var client
    let pane: PaneInfo

    var body: some View {
        VStack(spacing: 0) {
            if pane.kind == .browser {
                ContentUnavailableView {
                    Label(pane.title.isEmpty ? "Browser" : pane.title, systemImage: "globe")
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

    /// Multiplier over fit-to-width.
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @FocusState private var keyboardFocused: Bool

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
                let fit = available / (CGFloat(snapshot.cols) * Self.cellWidthPerPoint)
                let fontSize = min(Self.maxFont, max(Self.minFont, fit * zoom * pinch))
                let cellW = fontSize * Self.cellWidthPerPoint
                let lineH = (fontSize * Self.lineHeightPerPoint).rounded(.up)
                let contentW = CGFloat(snapshot.cols) * cellW
                let contentH = CGFloat(snapshot.rows) * lineH

                ScrollView([.horizontal, .vertical]) {
                    screen(snapshot, fontSize: fontSize, cellW: cellW, lineH: lineH)
                        .frame(width: contentW, height: contentH, alignment: .topLeading)
                        .padding(Self.padding)
                        // Top-align when the screen is shorter than the viewport; the bottom
                        // anchor below only matters when it is taller (keeps the prompt visible).
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                }
                .scrollBounceBehavior(.basedOnSize, axes: [.horizontal, .vertical])
                .defaultScrollAnchor(.bottomLeading)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(client.status.isLive ? "Waiting for screen…" : client.status.label)
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
                .onEnded { value in zoom = min(6, max(0.3, zoom * value.magnification)) }
        )
        .onTapGesture(count: 2) { withAnimation(.snappy) { zoom = 1 } }
        .onTapGesture { keyboardFocused = true }
        .focusable()
        .focused($keyboardFocused)
        .onKeyPress(phases: [.down, .repeat], action: handleHardwareKey)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Terminal screen")
        .accessibilityValue(snapshot?.lines.joined(separator: "\n") ?? "")
    }

    private func screen(_ s: ScreenSnapshot, fontSize: CGFloat, cellW: CGFloat, lineH: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(s.lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line.isEmpty ? " " : line)
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundStyle(Color(white: 0.92))
                        .lineLimit(1)
                        .fixedSize()
                        .frame(height: lineH, alignment: .leading)
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
    @FocusState private var fieldFocused: Bool

    private struct KeyButton: Identifiable {
        let id: String
        let label: String
        let key: SyncKey
        var systemImage: String?
    }

    private let keys: [KeyButton] = [
        .init(id: "esc", label: "esc", key: .escape),
        .init(id: "tab", label: "tab", key: .tab),
        .init(id: "up", label: "↑", key: .up, systemImage: "arrow.up"),
        .init(id: "down", label: "↓", key: .down, systemImage: "arrow.down"),
        .init(id: "left", label: "←", key: .left, systemImage: "arrow.left"),
        .init(id: "right", label: "→", key: .right, systemImage: "arrow.right"),
        .init(id: "ctrlc", label: "^C", key: .ctrlC),
        .init(id: "ctrld", label: "^D", key: .ctrlD),
        .init(id: "bksp", label: "⌫", key: .backspace, systemImage: "delete.left"),
        .init(id: "enter", label: "⏎", key: .enter, systemImage: "return"),
    ]

    var body: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button {
                        ctrlLatched.toggle()
                    } label: {
                        Text("ctrl").font(.callout.monospaced())
                            .frame(minWidth: 40, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .tint(ctrlLatched ? .accentColor : .secondary)
                    .accessibilityAddTraits(ctrlLatched ? .isSelected : [])

                    ForEach(keys) { k in
                        Button {
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
                        .accessibilityLabel(k.id)
                    }
                }
                .padding(.horizontal, 8)
            }
            HStack(spacing: 8) {
                TextField(ctrlLatched ? "ctrl + letter" : "Type a command", text: $text)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .focused($fieldFocused)
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
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func send(withEnter: Bool) {
        client.sendText(text, to: paneID)
        if withEnter { client.sendKey(.enter, to: paneID) }
        text = ""
        fieldFocused = true
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
