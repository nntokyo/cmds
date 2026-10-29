import CmdsCore
import SwiftUI
import UIKit

/// Text field whose keystrokes go straight to the terminal, so the Mac's line editor (and its cursor)
/// is the only copy of the line. IME composition (Japanese etc.) stays local until committed.
struct DirectInputField: UIViewRepresentable {
    var placeholder: String
    @Binding var ctrlLatched: Bool
    @Binding var isFocused: Bool
    let onText: (String) -> Void
    let onKey: (SyncKey) -> Void

    func makeUIView(context: Context) -> DirectInputTextField {
        let field = DirectInputTextField()
        field.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.inlinePredictionType = .no
        field.returnKeyType = .default
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.accessibilityIdentifier = "directInput"
        return field
    }

    func updateUIView(_ field: DirectInputTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholder = placeholder
        field.onKey = { [weak coordinator = context.coordinator] key in coordinator?.sendKey(key) }
        if isFocused, !field.isFirstResponder {
            DispatchQueue.main.async { field.becomeFirstResponder() }
        } else if !isFocused, field.isFirstResponder {
            DispatchQueue.main.async { field.resignFirstResponder() }
        }
    }

    /// One text line high; SwiftUI would otherwise stretch the field to fill the bar.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: DirectInputTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: uiView.intrinsicContentSize.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: DirectInputField

        init(parent: DirectInputField) { self.parent = parent }

        func sendKey(_ key: SyncKey) {
            parent.onKey(key)
            parent.ctrlLatched = false
        }

        @objc func editingChanged(_ field: UITextField) {
            // Wait while the IME is composing; send once the text is committed.
            guard field.markedTextRange == nil, let text = field.text, !text.isEmpty else { return }
            field.text = ""
            if parent.ctrlLatched, text.count == 1, let ch = text.lowercased().first, ch.isLetter || "@[\\]^_".contains(ch) {
                sendKey(.ctrl(ch))
                return
            }
            parent.onText(text)
            parent.ctrlLatched = false
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            editingChanged(field)
            sendKey(.enter)
            return false
        }

        func textFieldDidBeginEditing(_ field: UITextField) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            if parent.isFocused { parent.isFocused = false }
        }
    }
}

final class DirectInputTextField: UITextField {
    var onKey: ((SyncKey) -> Void)?

    /// Backspace on an empty field deletes on the Mac; with local IME text it edits the composition.
    override func deleteBackward() {
        if (text ?? "").isEmpty, markedTextRange == nil {
            onKey?(.backspace)
        } else {
            super.deleteBackward()
        }
    }

    /// Hardware keyboard: arrows, Esc and Tab go to the terminal instead of moving inside the field.
    /// While the IME is composing it keeps them (candidate selection, cancel).
    override var keyCommands: [UIKeyCommand]? {
        guard markedTextRange == nil else { return super.keyCommands }
        let mapping: [(String, UIKeyModifierFlags, Selector)] = [
            (UIKeyCommand.inputUpArrow, [], #selector(keyUp)),
            (UIKeyCommand.inputDownArrow, [], #selector(keyDown)),
            (UIKeyCommand.inputLeftArrow, [], #selector(keyLeft)),
            (UIKeyCommand.inputRightArrow, [], #selector(keyRight)),
            (UIKeyCommand.inputEscape, [], #selector(keyEscape)),
            ("\t", [], #selector(keyTab)),
            ("\t", .shift, #selector(keyBackTab)),
        ]
        return mapping.map { input, flags, action in
            let command = UIKeyCommand(input: input, modifierFlags: flags, action: action)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func keyUp() { onKey?(.up) }
    @objc private func keyDown() { onKey?(.down) }
    @objc private func keyLeft() { onKey?(.left) }
    @objc private func keyRight() { onKey?(.right) }
    @objc private func keyEscape() { onKey?(.escape) }
    @objc private func keyTab() { onKey?(.tab) }
    @objc private func keyBackTab() { onKey?(.backTab) }
}
