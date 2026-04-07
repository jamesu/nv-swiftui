import AppKit
import SwiftUI

final class NVSearchField: NSSearchField {
    private static weak var activeField: NVSearchField?
    private static let allFields = NSHashTable<NVSearchField>.weakObjects()

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
        Self.activeField = self
    }

    static func focusActiveField(selectAll: Bool = true, cursorAtEnd: Bool = false) {
        let candidates = allFields.allObjects
        let preferredField =
            activeField ??
            candidates.first(where: { $0.window?.isKeyWindow == true }) ??
            candidates.first(where: { $0.window?.isMainWindow == true }) ??
            candidates.first

        guard let preferredField else { return }
        preferredField.window?.makeKeyAndOrderFront(nil)
        preferredField.window?.makeFirstResponder(preferredField)
        if cursorAtEnd,
           let editor = preferredField.window?.fieldEditor(true, for: preferredField) as? NSTextView {
            let length = editor.string.count
            editor.setSelectedRange(NSRange(location: length, length: 0))
        } else if selectAll {
            preferredField.selectText(nil)
        }
        Self.activeField = preferredField
    }
}

struct AppKitControlField: NSViewRepresentable {
    let text: String
    let placeholder: String
    let selectAllOnBeginEditing: Bool
    let isEditingTitle: Bool
    let autoComplete: (String) -> String?
    let onChange: (String) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onMoveForward: () -> Void
    let onMoveBackward: () -> Void
    let onMoveToEditor: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selectAllOnBeginEditing: selectAllOnBeginEditing,
            isEditingTitle: isEditingTitle,
            autoComplete: autoComplete,
            onChange: onChange,
            onSubmit: onSubmit,
            onCancel: onCancel,
            onMoveForward: onMoveForward,
            onMoveBackward: onMoveBackward,
            onMoveToEditor: onMoveToEditor
        )
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NVSearchField()
        field.placeholderString = placeholder
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = true
        field.focusRingType = .default
        field.font = NSFont.systemFont(ofSize: 13)
        field.delegate = context.coordinator
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.selectAllOnBeginEditing = selectAllOnBeginEditing
        context.coordinator.isEditingTitle = isEditingTitle
        let isEditing = field.window?.firstResponder is NSTextView
        if isEditing,
           let prefix = context.coordinator.autocompletedPrefix,
           prefix == text,
           field.stringValue.hasPrefix(text) {
            return
        }
        if field.stringValue != text {
            context.coordinator.isProgrammaticUpdate = true
            context.coordinator.autocompletedPrefix = nil
            field.stringValue = text
            context.coordinator.isProgrammaticUpdate = false
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        weak var field: NSSearchField?
        var selectAllOnBeginEditing: Bool
        var isEditingTitle: Bool
        let autoComplete: (String) -> String?
        let onChange: (String) -> Void
        let onSubmit: () -> Void
        let onCancel: () -> Void
        let onMoveForward: () -> Void
        let onMoveBackward: () -> Void
        let onMoveToEditor: () -> Void
        var isProgrammaticUpdate = false
        var autocompletedPrefix: String?
        private var lastUserTypedValue = ""

        init(
            selectAllOnBeginEditing: Bool,
            isEditingTitle: Bool,
            autoComplete: @escaping (String) -> String?,
            onChange: @escaping (String) -> Void,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void,
            onMoveForward: @escaping () -> Void,
            onMoveBackward: @escaping () -> Void,
            onMoveToEditor: @escaping () -> Void
        ) {
            self.selectAllOnBeginEditing = selectAllOnBeginEditing
            self.isEditingTitle = isEditingTitle
            self.autoComplete = autoComplete
            self.onChange = onChange
            self.onSubmit = onSubmit
            self.onCancel = onCancel
            self.onMoveForward = onMoveForward
            self.onMoveBackward = onMoveBackward
            self.onMoveToEditor = onMoveToEditor
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            if let field {
                lastUserTypedValue = field.stringValue
            }
            guard selectAllOnBeginEditing,
                  let editor = obj.userInfo?["NSFieldEditor"] as? NSTextView else {
                return
            }
            editor.setSelectedRange(NSRange(location: 0, length: editor.string.count))
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field, !isProgrammaticUpdate else { return }
            let typedValue = field.stringValue
            let previousAutocompletedPrefix = autocompletedPrefix
            autocompletedPrefix = nil

            if typedValue.isEmpty && !lastUserTypedValue.isEmpty {
                lastUserTypedValue = ""
                onCancel()
                return
            }

            onChange(typedValue)

            guard let editor = obj.userInfo?["NSFieldEditor"] as? NSTextView else { return }
            let selectedRange = editor.selectedRange
            let wasDeletion = typedValue.count < lastUserTypedValue.count
            let changedSelection = selectedRange.location != typedValue.count || selectedRange.length != 0
            defer {
                if autocompletedPrefix == typedValue, field.stringValue.count > typedValue.count {
                    lastUserTypedValue = field.stringValue
                } else {
                    lastUserTypedValue = typedValue
                }
            }

            guard !wasDeletion, !changedSelection else { return }
            guard previousAutocompletedPrefix != typedValue else { return }
            guard selectedRange.length == 0, selectedRange.location == typedValue.count else { return }
            guard let suggestion = autoComplete(typedValue) else { return }
            guard suggestion != typedValue else { return }

            isProgrammaticUpdate = true
            field.stringValue = suggestion
            editor.string = suggestion
            editor.setSelectedRange(NSRange(location: typedValue.count, length: suggestion.count - typedValue.count))
            autocompletedPrefix = typedValue
            isProgrammaticUpdate = false
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                autocompletedPrefix = nil
                lastUserTypedValue = ""
                onCancel()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
                commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                autocompletedPrefix = nil
                if let field {
                    lastUserTypedValue = field.stringValue
                }
                onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) ||
                commandSelector == #selector(NSResponder.insertTabIgnoringFieldEditor(_:)) {
                onMoveForward()
                return true
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                onMoveBackward()
                return true
            }
            if isEditingTitle &&
                (commandSelector == #selector(NSResponder.moveToEndOfLine(_:)) ||
                 commandSelector == #selector(NSResponder.moveToRightEndOfLine(_:))) {
                let currentSelection = textView.selectedRange()
                if currentSelection.length == 0 && currentSelection.location == textView.string.count {
                    onMoveToEditor()
                    return true
                }
            }
            return false
        }
    }
}
