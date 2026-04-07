import AppKit
import SwiftUI

final class NVTagTextField: NSTextField {
    private static weak var activeField: NVTagTextField?
    private static let allFields = NSHashTable<NVTagTextField>.weakObjects()

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            Self.activeField = self
        }
        return accepted
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Self.allFields.add(self)
    }

    static func focusActiveField() {
        let candidates = allFields.allObjects
        let preferredField =
            activeField ??
            candidates.first(where: { $0.window?.isKeyWindow == true }) ??
            candidates.first(where: { $0.window?.isMainWindow == true }) ??
            candidates.first

        guard let preferredField else { return }
        preferredField.window?.makeFirstResponder(preferredField)
        if let editor = preferredField.window?.fieldEditor(true, for: preferredField) as? NSTextView {
            let length = editor.string.count
            editor.setSelectedRange(NSRange(location: length, length: 0))
        }
        Self.activeField = preferredField
    }
}

struct AppKitTagField: NSViewRepresentable {
    let text: String
    let isEditable: Bool
    let focusRequestID: Int
    let onChange: (String) -> Void
    let onSubmit: () -> Void
    let onMoveForward: () -> Void
    let onMoveBackward: () -> Void
    let onCancel: () -> Void
    let onFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onChange: onChange,
            onSubmit: onSubmit,
            onMoveForward: onMoveForward,
            onMoveBackward: onMoveBackward,
            onCancel: onCancel,
            onFocus: onFocus
        )
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NVTagTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 12)
        field.delegate = context.coordinator
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.focusRequestID = focusRequestID
        field.isEditable = isEditable
        if field.stringValue != text {
            context.coordinator.isProgrammaticUpdate = true
            field.stringValue = text
            context.coordinator.isProgrammaticUpdate = false
        }

        if context.coordinator.lastHandledFocusRequestID != focusRequestID {
            context.coordinator.lastHandledFocusRequestID = focusRequestID
            DispatchQueue.main.async {
                NVTagTextField.focusActiveField()
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        weak var field: NSTextField?
        let onChange: (String) -> Void
        let onSubmit: () -> Void
        let onMoveForward: () -> Void
        let onMoveBackward: () -> Void
        let onCancel: () -> Void
        let onFocus: () -> Void
        var isProgrammaticUpdate = false
        var focusRequestID = 0
        var lastHandledFocusRequestID = 0

        init(
            onChange: @escaping (String) -> Void,
            onSubmit: @escaping () -> Void,
            onMoveForward: @escaping () -> Void,
            onMoveBackward: @escaping () -> Void,
            onCancel: @escaping () -> Void,
            onFocus: @escaping () -> Void
        ) {
            self.onChange = onChange
            self.onSubmit = onSubmit
            self.onMoveForward = onMoveForward
            self.onMoveBackward = onMoveBackward
            self.onCancel = onCancel
            self.onFocus = onFocus
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field, !isProgrammaticUpdate else { return }
            onChange(field.stringValue)
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            onFocus()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let eventModifiers = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []

            if commandSelector == #selector(NSResponder.insertTab(_:)) ||
                commandSelector == #selector(NSResponder.insertTabIgnoringFieldEditor(_:)) {
                if eventModifiers.contains(.shift) {
                    onSubmit()
                    onMoveBackward()
                } else {
                    onSubmit()
                    onMoveForward()
                }
                return true
            }

            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                onSubmit()
                onMoveBackward()
                return true
            }

            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onCancel()
                return true
            }
            return false
        }
    }
}
