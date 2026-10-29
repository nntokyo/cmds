import AppKit

// Placeholder until the libghostty implementation lands: a read-only text view that echoes sent text.
@MainActor
final class GhosttyTerminalEngine: TerminalEngine {
    func makeSurface(config: TerminalLaunchConfig) -> TerminalSurface {
        PlaceholderSurface(config: config)
    }
}

@MainActor
private final class PlaceholderSurface: TerminalSurface {
    weak var delegate: TerminalSurfaceDelegate?
    let view: NSView
    private let textView: NSTextView
    var title: String { "placeholder" }
    let workingDirectory: String?

    init(config: TerminalLaunchConfig) {
        workingDirectory = config.workingDirectory
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = "terminal placeholder (cwd: \(config.workingDirectory ?? "~"))\n"
        view = scroll
    }

    func sendText(_ text: String) { textView.string += text }
    func focus() { view.window?.makeFirstResponder(textView) }
    func visibleText() -> String { textView.string }
    func scrollbackText(maxLines: Int) -> String { textView.string }
    func close() { delegate?.terminalSurfaceDidClose(self) }
}
