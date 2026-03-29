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

    static func focusActiveField() {
        let candidates = allFields.allObjects
        let preferredField =
            activeField ??
            candidates.first(where: { $0.window?.isKeyWindow == true }) ??
            candidates.first(where: { $0.window?.isMainWindow == true }) ??
            candidates.first

        guard let preferredField else { return }
        preferredField.window?.makeKeyAndOrderFront(nil)
        preferredField.window?.makeFirstResponder(preferredField)
        preferredField.selectText(nil)
        Self.activeField = preferredField
    }
}

struct AppKitControlField: NSViewRepresentable {
    let text: String
    let placeholder: String
    let selectAllOnBeginEditing: Bool
    let autoComplete: (String) -> String?
    let onChange: (String) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selectAllOnBeginEditing: selectAllOnBeginEditing,
            autoComplete: autoComplete,
            onChange: onChange,
            onSubmit: onSubmit,
            onCancel: onCancel
        )
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NVSearchField()
        field.placeholderString = placeholder
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = true
        field.focusRingType = .default
        field.font = NSFont.systemFont(ofSize: 13)
        field.target = context.coordinator
        field.action = #selector(Coordinator.didSubmit(_:))
        field.delegate = context.coordinator
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.selectAllOnBeginEditing = selectAllOnBeginEditing
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
        let autoComplete: (String) -> String?
        let onChange: (String) -> Void
        let onSubmit: () -> Void
        let onCancel: () -> Void
        var isProgrammaticUpdate = false
        var autocompletedPrefix: String?
        private var lastUserTypedValue = ""

        init(
            selectAllOnBeginEditing: Bool,
            autoComplete: @escaping (String) -> String?,
            onChange: @escaping (String) -> Void,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.selectAllOnBeginEditing = selectAllOnBeginEditing
            self.autoComplete = autoComplete
            self.onChange = onChange
            self.onSubmit = onSubmit
            self.onCancel = onCancel
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

        @objc
        func didSubmit(_ sender: Any?) {
            autocompletedPrefix = nil
            if let field {
                lastUserTypedValue = field.stringValue
            }
            onSubmit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                autocompletedPrefix = nil
                lastUserTypedValue = ""
                onCancel()
                return true
            }
            return false
        }
    }
}
