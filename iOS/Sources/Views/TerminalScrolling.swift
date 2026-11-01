import SwiftUI

// How the terminal screen's scroll view keeps the rows in view while output arrives (`TerminalScreenView`), and the UI
// test probes of the rows on screen (`-uiTestProbes`).

/// Which part of the content the scroll view keeps in place when the content's size changes. Normally the bottom:
/// earlier output arrives above the screen, and the prompt stays where it is. While reading earlier output that a Mac
/// streams (iOS 18), the top: the rows that scrolled off the screen are added between the earlier output and the screen
/// while the screen's own rows move up by as many rows, so every row already there stays where it is.
struct ScrollAnchors: ViewModifier {
    let keepTop: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .defaultScrollAnchor(.bottomLeading, for: .initialOffset)
                .defaultScrollAnchor(.bottomLeading, for: .alignment)
                .defaultScrollAnchor(keepTop ? .topLeading : .bottomLeading, for: .sizeChanges)
        } else {
            content.defaultScrollAnchor(.bottomLeading)
        }
    }
}

/// Whether a row of the scroll view's content (`rowTop` from the content's top) is on screen: `visible` turns false only
/// when the user scrolls it away. When a change of the content pushes it off screen meanwhile (rows added above it
/// faster than the scroll view keeps the bottom in place), `lost` brings it back. Needs iOS 18
/// (`onScrollGeometryChange`); on iOS 17 the row always counts as visible and no earlier output is shown, so the
/// screen keeps following the prompt as before.
struct RowVisibility: ViewModifier {
    let rowTop: CGFloat
    let rowHeight: CGFloat
    @Binding var visible: Bool
    /// Called right when `visible` changes, before the view updates.
    let changed: (Bool) -> Void
    /// The row left the screen while `visible` without the user scrolling: bring it back.
    let lost: () -> Void
    @State private var onScreen = true
    /// The user drags the content, or it decelerates after a drag.
    @State private var userScrolling = false

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: Bool.self) { scroll in
                    scroll.visibleRect.maxY > rowTop && scroll.visibleRect.minY < rowTop + rowHeight
                } action: { _, now in
                    onScreen = now
                    update()
                }
                .onScrollPhaseChange { _, phase in
                    userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                    update()
                }
        } else {
            content
        }
    }

    private func update() {
        if onScreen != visible, onScreen || userScrolling {
            visible = onScreen
            changed(onScreen)
        } else if !onScreen, visible, !userScrolling {
            // Once the scroll view has settled (it may keep the bottom in place by itself).
            DispatchQueue.main.async {
                if !onScreen, visible, !userScrolling { lost() }
            }
        }
    }
}

/// UI tests (`-uiTestProbes`): the content rows on screen, as row indices.
struct ProbedViewport: Equatable {
    /// Top of the visible part, in points from the content's top.
    var top: CGFloat
    var rows: ClosedRange<Int>
}

/// UI tests (`-uiTestProbes`, iOS 18): records which rows (`rowTop` + index × `rowHeight`) are on screen.
struct ViewportProbe: ViewModifier {
    let rowTop: CGFloat
    let rowHeight: CGFloat
    @Binding var viewport: ProbedViewport?

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            if TerminalScreenView.showsTestProbes {
                content.onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, rect in
                    let first = Int(((rect.minY - rowTop) / rowHeight).rounded(.down))
                    let last = Int(((rect.maxY - rowTop) / rowHeight).rounded(.up)) - 1
                    viewport = ProbedViewport(top: rect.minY, rows: max(0, first)...max(0, first, last))
                }
            } else {
                content
            }
        } else {
            content
        }
    }
}

/// UI tests (`-uiTestProbes`): `terminalRows` (every row, earlier output first) and `terminalViewport` (the rows on
/// screen, after a line with their indices and the top of the visible part) as accessibility values.
struct TerminalTestProbes: View {
    let rows: [String]
    let viewport: ProbedViewport?

    var body: some View {
        ZStack {
            probe("terminalRows", rows.joined(separator: "\n"))
            probe("terminalViewport", viewportText)
        }
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
    }

    private var viewportText: String {
        guard let viewport, !rows.isEmpty else { return "" }
        let shown = min(viewport.rows.lowerBound, rows.count - 1)...min(viewport.rows.upperBound, rows.count - 1)
        return (["rows \(shown.lowerBound)-\(shown.upperBound) top \(Int(viewport.top.rounded()))"] + rows[shown])
            .joined(separator: "\n")
    }

    private func probe(_ id: String, _ value: String) -> some View {
        Color.clear
            .accessibilityElement()
            .accessibilityLabel(id)
            .accessibilityValue(value)
            .accessibilityIdentifier(id)
    }
}
