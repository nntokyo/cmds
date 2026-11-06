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
            } else if pane.kind == .files {
                // Browsing a Mac folder from the phone comes later (#26): the folder it shows, for now.
                ContentUnavailableView {
                    Label(pane.title, systemImage: "folder")
                } description: {
                    VStack {
                        Text("Files pane on the Mac")
                        if let folder = pane.workingDirectory { Text(folder).font(.caption.monospaced()) }
                    }
                }
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
    /// Earlier output shown above the screen with a Mac that does not stream it (`CompanionClient.histories`). Taken
    /// over only while following, so a refresh never moves the text the user is reading.
    @State private var history = PaneHistory()
    /// The focus row is on screen, so new output keeps it in view. Scrolling it away (into earlier output, or
    /// panning a zoomed screen) stops that until the user scrolls back or taps Latest.
    @State private var following = true
    /// Bumped by the Latest button (outside the scroll view reader).
    @State private var latestRequests = 0
    /// UI tests (`-uiTestProbes`): the rows on screen.
    @State private var probedViewport: ProbedViewport?

    /// Focus row vertically centred, line starts at the left edge (centring a long row horizontally would
    /// scroll the start of every line off screen).
    private static let focusAnchor = UnitPoint(x: 0, y: 0.5)
    private static let minFont: CGFloat = 5
    private static let maxFont: CGFloat = 36
    private static let padding: CGFloat = 6
    private static var cellWidthPerPoint: CGFloat { TerminalGrid.cellWidthPerPoint }
    private static let lineHeightPerPoint: CGFloat = {
        UIFont.monospacedSystemFont(ofSize: 100, weight: .regular).lineHeight / 100
    }()

    var body: some View {
        GeometryReader { geo in
            if let snapshot, snapshot.cols > 0 {
                let above = shownHistory
                let available = geo.size.width - Self.padding * 2
                let base = textMode == .fixed ? CGFloat(fixedFontSize)
                    : available / (CGFloat(snapshot.cols) * Self.cellWidthPerPoint)
                let fontSize = min(Self.maxFont, max(Self.minFont, base * zoom * pinch))
                let cellW = fontSize * Self.cellWidthPerPoint
                let lineH = (fontSize * Self.lineHeightPerPoint).rounded(.up)
                let contentW = CGFloat(snapshot.cols) * cellW
                let contentH = CGFloat(above.lines.count + snapshot.rows) * lineH

                ScrollViewReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        screen(snapshot, above: above, fontSize: fontSize, cellW: cellW, lineH: lineH)
                            .frame(width: contentW, height: contentH, alignment: .topLeading)
                            .padding(Self.padding)
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                    }
                    .modifier(ScrollAnchors(keepTop: client.streamsHistory && !following))
                    .scrollBounceBehavior(.basedOnSize, axes: [.horizontal, .vertical])
                    .modifier(RowVisibility(
                        rowTop: Self.padding + CGFloat(above.lines.count + Self.focusRow(snapshot)) * lineH,
                        rowHeight: lineH, visible: $following,
                        // At once, so no screen update in between drops rows above the ones being read. (Reading
                        // ends in `onChange(of: following)`, once the scroll view keeps the bottom in place again.)
                        changed: { if !$0 { client.setReadingHistory(paneID: paneID, reading: true) } },
                        lost: { scrollToFocus(proxy, snapshot) }))
                    .modifier(ViewportProbe(rowTop: Self.padding, rowHeight: lineH, viewport: $probedViewport))
                    // The terminal grid is usually taller than the phone; follow the cursor (the prompt) instead
                    // of pinning to the bottom, where a mostly empty screen shows only blank rows.
                    .onAppear { scrollToFocus(proxy, snapshot) }
                    // While following: the focus row moved (also with the cursor hidden), the earlier output above
                    // it grew or shrank (older Macs; streamed rows keep the bottom in place, see `ScrollAnchors`),
                    // or the text size changed.
                    .onChange(of: Self.focusRow(snapshot)) { if following { scrollToFocus(proxy, snapshot) } }
                    .onChange(of: history.lines.count) {
                        if following, !client.streamsHistory { scrollToFocus(proxy, snapshot) }
                    }
                    .onChange(of: fontSize) { if following { scrollToFocus(proxy, snapshot) } }
                    .onChange(of: latestRequests) {
                        // The newest earlier output first, then the scroll once its rows are laid out: rows taken
                        // over mid-scroll would move its target.
                        adoptHistory()
                        client.showLatestHistory(paneID: paneID)
                        DispatchQueue.main.async {
                            withAnimation(.snappy) { scrollToFocus(proxy, snapshot) }
                        }
                    }
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
        .onAppear {
            if let saved = TerminalTextSettings.savedZoom(paneID: paneID) { zoom = saved }
            adoptHistory()
        }
        .onDisappear { client.setReadingHistory(paneID: paneID, reading: false) }
        // Output scrolled the screen (its top row changed): ask for the rows that left it, while following. Also
        // once the pane is streamed from a Mac that answers (again), e.g. back on a pane whose screen did not move.
        // A Mac that streams these rows is asked only until it answered (`refreshHistory`).
        .onChange(of: snapshot.map(Self.topRow), initial: true) {
            if following, Self.showsHistory { client.refreshHistory(paneID: paneID) }
        }
        .onChange(of: client.canRequestHistory(paneID: paneID)) { _, can in
            // Streamed rows that arrive while reading wait in the client until reading ends.
            if can, following || client.streamsHistory, Self.showsHistory { client.refreshHistory(paneID: paneID) }
        }
        .onChange(of: client.histories[paneID]) { if following, !client.streamsHistory { adoptHistory() } }
        .onChange(of: client.streamsHistory) { adoptHistory() }
        .onChange(of: following) { _, now in
            guard now, Self.showsHistory else { return }
            client.setReadingHistory(paneID: paneID, reading: false)
            adoptHistory()
            client.refreshHistory(paneID: paneID)
        }
        .onTapGesture { keyboardFocused = true }
        .focusable()
        .focused($keyboardFocused)
        .onKeyPress(phases: [.down, .repeat], action: handleHardwareKey)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Terminal screen")
        .accessibilityIdentifier("terminalScreen")
        .accessibilityValue(snapshot?.lines.joined(separator: "\n") ?? "")
        // Outside the screen's accessibility element, which ignores its children.
        .overlay(alignment: .bottomTrailing) {
            if !following, snapshot != nil {
                Button { latestRequests += 1 } label: {
                    Label("Latest", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(10)
                .accessibilityHint(Text("Scrolls back to the live screen."))
                .accessibilityIdentifier("terminalLatest")
            }
        }
        .overlay(alignment: .topLeading) {
            if Self.showsTestProbes, let snapshot {
                TerminalTestProbes(rows: shownHistory.lines + snapshot.lines, viewport: probedViewport)
            }
        }
    }

    /// Rows above the screen. A Mac that streams them (`SyncFeature.scrollbackStream`) keeps them continuous, and the
    /// client changes them only at the bottom while they are read, so they are shown as they come; with other Macs
    /// the copy taken while following.
    private var shownHistory: PaneHistory {
        client.streamsHistory ? client.histories[paneID] ?? PaneHistory() : history
    }

    /// UI tests: the rows on screen and all rows as accessibility values (`TerminalScreenTests`).
    static let showsTestProbes = ProcessInfo.processInfo.arguments.contains("-uiTestProbes")

    /// Row to keep in view: the cursor row, else the last non-empty row. Each row view carries its index as
    /// scroll id. (A single zero-content anchor view pushed down with padding did not work: scrollTo left a
    /// zoomed full-screen TUI scrolled to its empty middle rows, i.e. a blank screen.)
    static func focusRow(_ s: ScreenSnapshot) -> Int {
        if let row = s.cursorRow, s.lines.indices.contains(row) { return row }
        return s.lines.lastIndex { !$0.isEmpty } ?? 0
    }

    private func scrollToFocus(_ proxy: ScrollViewProxy, _ s: ScreenSnapshot) {
        proxy.scrollTo(Self.focusRow(s), anchor: Self.focusAnchor)
    }

    /// Older Macs: shows the client's latest earlier output of this pane.
    private func adoptHistory() {
        history = client.histories[paneID] ?? PaneHistory()
    }

    /// Earlier output needs to know when the user scrolled away from the prompt (`RowVisibility`, iOS 18): without
    /// that, every refresh would move the rows being read.
    static var showsHistory: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    /// The first non-empty row and its index: changes when output scrolls the screen.
    static func topRow(_ s: ScreenSnapshot) -> String {
        guard let row = s.lines.firstIndex(where: { !$0.isEmpty }) else { return "" }
        return "\(row):\(s.lines[row])"
    }

    /// Earlier output first (`HistoryRowID`s), then the screen (row ids 0 … rows-1, which `focusRow` uses).
    private func screen(_ s: ScreenSnapshot, above: PaneHistory, fontSize: CGFloat, cellW: CGFloat,
                        lineH: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                TerminalHistoryRows(history: above, fontSize: fontSize, lineH: lineH).equatable()
                ForEach(Array(s.lines.enumerated()), id: \.offset) { row, line in
                    TerminalRow(line: line, fontSize: fontSize, lineH: lineH).id(row)
                }
            }
            if let row = s.cursorRow, let col = s.cursorCol, row >= 0, row < s.rows {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.65))
                    .frame(width: max(2, cellW), height: lineH)
                    .offset(x: CGFloat(col) * cellW, y: CGFloat(above.lines.count + row) * lineH)
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

/// One terminal row, exactly one line high.
private struct TerminalRow: View {
    let line: String
    let fontSize: CGFloat
    let lineH: CGFloat

    var body: some View {
        TerminalGrid.text(line.isEmpty ? " " : line, fontSize: fontSize)
            .font(.system(size: fontSize, design: .monospaced))
            .foregroundStyle(Color(white: 0.92))
            .lineLimit(1)
            .fixedSize()
            .frame(height: lineH, alignment: .leading)
    }
}

/// Scroll ids of the rows above the screen (`ForEach` ids are scroll targets as well): types of their own, so they
/// never match a screen row's index (`focusRow`).
private struct HistoryBlockID: Hashable { let index: Int }
private struct HistoryRowID: Hashable { let index: Int }

/// The rows above the screen, in blocks by row number (`PaneHistory.first`): rows added at the bottom or dropped at the
/// top rebuild only the blocks they touch. Equatable, so the many screen updates alone rebuild nothing.
private struct TerminalHistoryRows: View, Equatable {
    let history: PaneHistory
    let fontSize: CGFloat
    let lineH: CGFloat
    private static let blockRows = 128

    var body: some View {
        let first = history.first
        let end = first + history.lines.count
        let blocks = end > first ? Array((first / Self.blockRows)...((end - 1) / Self.blockRows)) : []
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks.map(HistoryBlockID.init(index:)), id: \.self) { block in
                let start = max(first, block.index * Self.blockRows)
                let stop = min(end, (block.index + 1) * Self.blockRows)
                TerminalHistoryBlock(lines: history.lines[(start - first)..<(stop - first)], firstRow: start,
                                     fontSize: fontSize, lineH: lineH)
                    .equatable()
            }
        }
    }
}

private struct TerminalHistoryBlock: View, Equatable {
    let lines: ArraySlice<String>
    /// Row number of the first of `lines`.
    let firstRow: Int
    let fontSize: CGFloat
    let lineH: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach((firstRow..<firstRow + lines.count).map(HistoryRowID.init(index:)), id: \.self) { row in
                TerminalRow(line: lines[lines.startIndex + row.index - firstRow], fontSize: fontSize, lineH: lineH)
            }
        }
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
                            .frame(minWidth: 32, maxWidth: 240, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .tint(.accentColor)
                    .accessibilityHint(lineMode && !text.isEmpty ? "Adds this text to the line being typed" : "Sends this text and Return")
                    .accessibilityAction(named: Text("Insert without Enter")) { sendQuickReply(reply, withEnter: false) }
                    .accessibilityIdentifier("quickReply\(index)")
                    .contextMenu {
                        Button("Insert without Enter") { sendQuickReply(reply, withEnter: false) }
                    }
                    // A button (and its menu) is never reused for another shortcut after the list is edited.
                    .id(reply)
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

    /// Tap sends the shortcut and Return; Insert types it without Return. In line mode a shortcut never
    /// sends a line you are still composing: with text in the field (or for Insert) it is added to the
    /// field instead, for you to send with return.
    private func sendQuickReply(_ reply: String, withEnter: Bool) {
        // First, so the field's ctrl handling does not turn an inserted one-letter shortcut into a chord.
        ctrlLatched = false
        if lineMode && (!withEnter || !text.isEmpty) {
            text += reply
            lineFieldFocused = true
            return
        }
        sendToPane(reply, withEnter: withEnter)
        if !lineMode && !withEnter { directFocused = true }
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

/// The terminal's cell grid on the phone. The Mac sends a row as its text, without the spacer cell after a wide
/// character; a monospaced font draws ASCII on the grid, but wide characters (Japanese, Chinese, Korean, emoji) and
/// symbols from fallback fonts come out narrower or wider than their cells, so the cursor and later columns drifted
/// (#115). `text` gives every other character an advance of exactly its cells.
@MainActor
enum TerminalGrid {
    /// Advance width of one monospaced cell per point of font size.
    static let cellWidthPerPoint: CGFloat = {
        let font = UIFont.monospacedSystemFont(ofSize: 100, weight: .regular)
        return ("M" as NSString).size(withAttributes: [.font: font]).width / 100
    }()

    /// Drawn advance per point of font size of characters outside ASCII, measured once each.
    private static var advances: [Character: CGFloat] = [:]
    private static let measuringFont = UIFont.monospacedSystemFont(ofSize: 100, weight: .regular)

    private static func advancePerPoint(_ character: Character) -> CGFloat {
        if let known = advances[character] { return known }
        let width = (String(character) as NSString).size(withAttributes: [.font: measuringFont]).width / 100
        advances[character] = width
        return width
    }

    /// `line` laid out on the grid: ASCII runs as they are; each run of other characters with the same correction
    /// gets kerning so every character takes `TerminalCells.width` cells.
    static func text(_ line: String, fontSize: CGFloat) -> Text {
        guard line.unicodeScalars.contains(where: { !$0.isASCII }) else { return Text(verbatim: line) }
        var result = Text(verbatim: "")
        var run = ""
        var runKerning: CGFloat?
        func flush() {
            guard !run.isEmpty else { return }
            let segment = Text(verbatim: run)
            result = result + (runKerning.map { segment.kerning($0) } ?? segment)
            run = ""
        }
        for character in line {
            let kerning: CGFloat? = character.isASCII ? nil
                : (CGFloat(TerminalCells.width(of: character)) * cellWidthPerPoint - advancePerPoint(character)) * fontSize
            if kerning != runKerning {
                flush()
                runKerning = kerning
            }
            run.append(character)
        }
        flush()
        return result
    }
}
