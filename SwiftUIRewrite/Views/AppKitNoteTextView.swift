import AppKit
import SwiftUI

protocol AppKitNoteTextViewFormattingDelegate: AnyObject {
    func noteTextViewDidApplyFormatting(_ textView: NSTextView)
}

final class NVEditorTextView: NSTextView {
    private static weak var activeTextView: NVEditorTextView?
    private static var currentSelectedNoteID: UUID?
    private static var defaultPlainTextAttributes: [NSAttributedString.Key: Any] = [:]
    var noteID: UUID?
    var onUndoCommand: (() -> Void)?
    var onRedoCommand: (() -> Void)?
    var onMoveToTitleEditing: (() -> Void)?
    var onMoveToTagEditing: (() -> Void)?
    var onMoveFocusForward: (() -> Void)?
    var onMoveFocusBackward: (() -> Void)?
    var usesSoftTabs = true
    var tabWidth = 4

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            Self.activeTextView = self
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, Self.activeTextView === self {
            Self.activeTextView = nil
        }
        return resigned
    }

    static func toggleBoldOnActiveTextView() {
        activeTextView?.applyFormatting { textView in
            textView.toggleFontTrait(.boldFontMask)
        }
    }

    static func toggleItalicsOnActiveTextView() {
        activeTextView?.applyFormatting { textView in
            textView.toggleFontTrait(.italicFontMask)
        }
    }

    static func toggleUnderlineOnActiveTextView() {
        activeTextView?.applyFormatting { textView in
            textView.toggleUnderlineStyle()
        }
    }

    static func toggleStrikethroughOnActiveTextView() {
        activeTextView?.applyFormatting { textView in
            textView.toggleStrikethroughStyle()
        }
    }

    static func alignLeftOnActiveTextView() {
        activeTextView?.applyFormatting { textView in
            textView.applyParagraphStyle { style in
                style.alignment = .left
            }
        }
    }

    static func alignCenterOnActiveTextView() {
        activeTextView?.applyFormatting { textView in
            textView.applyParagraphStyle { style in
                style.alignment = .center
            }
        }
    }

    static func alignRightOnActiveTextView() {
        activeTextView?.applyFormatting { textView in
            textView.applyParagraphStyle { style in
                style.alignment = .right
            }
        }
    }

    static func increaseIndentOnActiveTextView() {
        activeTextView?.applyFormatting { textView in
            textView.applyParagraphStyle { style in
                style.headIndent += 18
                style.firstLineHeadIndent += 18
            }
        }
    }

    static func decreaseIndentOnActiveTextView() {
        activeTextView?.applyFormatting { textView in
            textView.applyParagraphStyle { style in
                style.headIndent = max(0, style.headIndent - 18)
                style.firstLineHeadIndent = max(0, style.firstLineHeadIndent - 18)
            }
        }
    }

    static func toggleBulletListOnActiveTextView() {
        activeTextView?.applyFormatting { textView in
            textView.toggleBulletList()
        }
    }

    static func makePlainTextOnActiveTextView() {
        activeTextView?.applyFormatting { textView in
            textView.makePlainText()
        }
    }

    static func showFontPanelForActiveTextView() {
        guard let activeTextView else { return }
        activeTextView.window?.makeFirstResponder(activeTextView)
        let manager = NSFontManager.shared
        manager.target = activeTextView
        manager.orderFrontFontPanel(nil)
    }

    static func findNextOccurrenceOnActiveTextView(terms: [String]) {
        activeTextView?.selectOccurrence(of: terms, forward: true)
    }

    static func findPreviousOccurrenceOnActiveTextView(terms: [String]) {
        activeTextView?.selectOccurrence(of: terms, forward: false)
    }

    @discardableResult
    static func openLinkAtInsertionPointOnActiveTextView() -> Bool {
        activeTextView?.openLinkAtInsertionPoint() ?? false
    }

    static func focusActiveTextView() {
        guard let activeTextView else { return }
        activeTextView.window?.makeFirstResponder(activeTextView)
    }

    static func setActiveTextView(_ textView: NVEditorTextView?) {
        activeTextView = textView
    }

    static func setCurrentSelectedNoteID(_ noteID: UUID?) {
        currentSelectedNoteID = noteID
    }

    static func setDefaultPlainTextAttributes(_ attributes: [NSAttributedString.Key: Any]) {
        defaultPlainTextAttributes = attributes
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let lowercasedCharacters = event.charactersIgnoringModifiers?.lowercased()
        let isUndoShortcut = modifiers == [.command] && lowercasedCharacters == "z"
        let isRedoShortcut = modifiers == [.command, .shift] && lowercasedCharacters == "z"

        if isUndoShortcut || isRedoShortcut {
            guard noteID == Self.currentSelectedNoteID else { return true }
            if isUndoShortcut {
                onUndoCommand?()
                return true
            }
            if isRedoShortcut {
                onRedoCommand?()
                return true
            }
        }

        return super.performKeyEquivalent(with: event)
    }

    override func moveToBeginningOfLine(_ sender: Any?) {
        if jumpToTitleEditingIfNeeded() {
            return
        }
        super.moveToBeginningOfLine(sender)
    }

    override func moveToLeftEndOfLine(_ sender: Any?) {
        if jumpToTitleEditingIfNeeded() {
            return
        }
        super.moveToLeftEndOfLine(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        onMoveToTagEditing?()
    }

    override func insertTab(_ sender: Any?) {
        guard isEditable else { return }
        let insertion = usesSoftTabs ? String(repeating: " ", count: max(1, tabWidth)) : "\t"
        insertText(insertion, replacementRange: selectedRange())
    }

    private func applyFormatting(_ operation: (NVEditorTextView) -> Void) {
        guard isEditable else { return }
        operation(self)
        (delegate as? AppKitNoteTextViewFormattingDelegate)?.noteTextViewDidApplyFormatting(self)
    }

    private func jumpToTitleEditingIfNeeded() -> Bool {
        guard selectedRange() == NSRange(location: 0, length: 0) else { return false }
        onMoveToTitleEditing?()
        return true
    }

    private func selectOccurrence(of terms: [String], forward: Bool) {
        let nsString = string as NSString
        guard nsString.length > 0 else { return }

        let normalizedTerms = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedTerms.isEmpty else { return }

        let currentSelection = selectedRange()
        let pivot = forward ? NSMaxRange(currentSelection) : currentSelection.location
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        var candidate: NSRange?

        if forward {
            for term in normalizedTerms {
                let start = min(pivot, nsString.length)
                let firstPassRange = NSRange(location: start, length: nsString.length - start)
                let match = nsString.range(of: term, options: options, range: firstPassRange)
                if match.location != NSNotFound,
                   candidate.map({ match.location < $0.location }) ?? true {
                    candidate = match
                }
            }

            if candidate == nil, pivot > 0 {
                for term in normalizedTerms {
                    let wrappedRange = NSRange(location: 0, length: min(pivot, nsString.length))
                    let match = nsString.range(of: term, options: options, range: wrappedRange)
                    if match.location != NSNotFound,
                       candidate.map({ match.location < $0.location }) ?? true {
                        candidate = match
                    }
                }
            }
        } else {
            for term in normalizedTerms {
                let firstPassRange = NSRange(location: 0, length: min(pivot, nsString.length))
                let match = nsString.range(of: term, options: options.union(.backwards), range: firstPassRange)
                if match.location != NSNotFound,
                   candidate.map({ match.location > $0.location }) ?? true {
                    candidate = match
                }
            }

            if candidate == nil, pivot < nsString.length {
                for term in normalizedTerms {
                    let start = min(pivot, nsString.length)
                    let wrappedRange = NSRange(location: start, length: nsString.length - start)
                    let match = nsString.range(of: term, options: options.union(.backwards), range: wrappedRange)
                    if match.location != NSNotFound,
                       candidate.map({ match.location > $0.location }) ?? true {
                        candidate = match
                    }
                }
            }
        }

        guard let candidate else { return }
        window?.makeFirstResponder(self)
        setSelectedRange(candidate)
        scrollRangeToVisible(candidate)
    }

    private func openLinkAtInsertionPoint() -> Bool {
        let selection = selectedRange()
        let candidateIndexes = [selection.location, max(0, selection.location - 1)]
        guard let textStorage else { return false }

        for index in candidateIndexes {
            guard index >= 0, index < textStorage.length else { continue }
            if let url = textStorage.attribute(.link, at: index, effectiveRange: nil) as? URL {
                NSWorkspace.shared.open(url)
                return true
            }
            if let urlString = textStorage.attribute(.link, at: index, effectiveRange: nil) as? String,
               let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
                return true
            }
        }

        return false
    }

    private func makePlainText() {
        let plainAttributes = Self.defaultPlainTextAttributes.isEmpty
            ? [.font: (font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)),
               .foregroundColor: (textColor ?? NSColor.textColor)]
            : Self.defaultPlainTextAttributes

        if selectedRange().length == 0 {
            typingAttributes = plainAttributes
            return
        }

        let range = selectedRange()
        textStorage?.beginEditing()
        textStorage?.setAttributes(plainAttributes, range: range)
        textStorage?.endEditing()
    }

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        let range = selectedRange()
        let fontManager = NSFontManager.shared

        if range.length == 0 {
            var typingAttributes = typingAttributes
            let currentFont = (typingAttributes[.font] as? NSFont) ?? font ?? .systemFont(ofSize: NSFont.systemFontSize)
            typingAttributes[.font] = toggledFont(from: currentFont, trait: trait, fontManager: fontManager)
            self.typingAttributes = typingAttributes
            return
        }

        textStorage?.beginEditing()
        textStorage?.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let currentFont = (value as? NSFont) ?? self.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            let updatedFont = self.toggledFont(from: currentFont, trait: trait, fontManager: fontManager)
            self.textStorage?.addAttribute(.font, value: updatedFont, range: subrange)
        }
        textStorage?.endEditing()
    }

    private func toggledFont(from font: NSFont, trait: NSFontTraitMask, fontManager: NSFontManager) -> NSFont {
        let currentTraits = fontManager.traits(of: font)
        if currentTraits.contains(trait) {
            return fontManager.convert(font, toNotHaveTrait: trait)
        }
        return fontManager.convert(font, toHaveTrait: trait)
    }

    private func toggleUnderlineStyle() {
        let range = selectedRange()

        if range.length == 0 {
            var typingAttributes = typingAttributes
            let currentStyle = typingAttributes[.underlineStyle] as? Int ?? 0
            typingAttributes[.underlineStyle] = currentStyle == 0 ? NSUnderlineStyle.single.rawValue : 0
            self.typingAttributes = typingAttributes
            return
        }

        let currentStyle = textStorage?.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0
        let newStyle = currentStyle == 0 ? NSUnderlineStyle.single.rawValue : 0
        textStorage?.addAttribute(.underlineStyle, value: newStyle, range: range)
    }

    private func toggleStrikethroughStyle() {
        let range = selectedRange()

        if range.length == 0 {
            var typingAttributes = typingAttributes
            let currentStyle = typingAttributes[.strikethroughStyle] as? Int ?? 0
            typingAttributes[.strikethroughStyle] = currentStyle == 0 ? NSUnderlineStyle.single.rawValue : 0
            self.typingAttributes = typingAttributes
            return
        }

        let currentStyle = textStorage?.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) as? Int ?? 0
        let newStyle = currentStyle == 0 ? NSUnderlineStyle.single.rawValue : 0
        textStorage?.addAttribute(.strikethroughStyle, value: newStyle, range: range)
    }

    private func applyParagraphStyle(_ mutate: (NSMutableParagraphStyle) -> Void) {
        let paragraphRange = (string as NSString).paragraphRange(for: selectedRange())
        guard paragraphRange.length > 0 else { return }

        textStorage?.beginEditing()
        textStorage?.enumerateAttribute(.paragraphStyle, in: paragraphRange, options: []) { value, subrange, _ in
            let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            mutate(style)
            self.textStorage?.addAttribute(.paragraphStyle, value: style, range: subrange)
        }
        textStorage?.endEditing()
    }

    private func toggleBulletList() {
        guard let textStorage else { return }
        let paragraphRange = (string as NSString).paragraphRange(for: selectedRange())
        guard paragraphRange.length > 0 else { return }

        let paragraphText = (string as NSString).substring(with: paragraphRange)
        let lines = paragraphText.components(separatedBy: "\n")
        let bulletPrefix = "\u{2022} "
        let shouldRemoveBullets = lines.allSatisfy { line in
            line.isEmpty || line.hasPrefix(bulletPrefix)
        }

        var rebuilt = ""
        for (index, line) in lines.enumerated() {
            let updatedLine: String
            if shouldRemoveBullets {
                updatedLine = line.hasPrefix(bulletPrefix) ? String(line.dropFirst(bulletPrefix.count)) : line
            } else {
                updatedLine = line.isEmpty ? bulletPrefix : bulletPrefix + line
            }
            rebuilt.append(updatedLine)
            if index < lines.count - 1 {
                rebuilt.append("\n")
            }
        }

        let replacement = NSAttributedString(
            string: rebuilt,
            attributes: textStorage.attributes(at: min(paragraphRange.location, max(0, textStorage.length - 1)), effectiveRange: nil)
        )

        textStorage.beginEditing()
        textStorage.replaceCharacters(in: paragraphRange, with: replacement)
        textStorage.endEditing()
        setSelectedRange(NSRange(location: paragraphRange.location, length: replacement.length))
    }

    override func changeFont(_ sender: Any?) {
        let fontManager = NSFontManager.shared
        if selectedRange().length == 0 {
            var attributes = typingAttributes
            let currentFont = (attributes[.font] as? NSFont) ?? font ?? .systemFont(ofSize: NSFont.systemFontSize)
            attributes[.font] = fontManager.convert(currentFont)
            typingAttributes = attributes
            (delegate as? AppKitNoteTextViewFormattingDelegate)?.noteTextViewDidApplyFormatting(self)
            return
        }

        super.changeFont(sender)
        (delegate as? AppKitNoteTextViewFormattingDelegate)?.noteTextViewDidApplyFormatting(self)
    }
}

struct AppKitNoteTextView: NSViewRepresentable {
    let noteID: UUID
    let attributedText: NSAttributedString
    let selection: NSRange
    let fontName: String
    let fontSize: CGFloat
    let foregroundColor: NSColor
    let backgroundColor: NSColor
    let usesSoftTabs: Bool
    let tabWidth: Int
    let isEditable: Bool
    let refreshGeneration: Int
    let focusRequestID: Int
    let searchHighlightTerms: [String]
    let searchHighlightColor: NSColor
    let onBeginEditing: () -> Void
    let onTextChange: (NSAttributedString, NSRange) -> Void
    let onSelectionChange: (NSRange) -> Void
    let onUndoCommand: () -> Void
    let onRedoCommand: () -> Void
    let onMoveToTitleEditing: () -> Void
    let onMoveToTagEditing: () -> Void
    let onMoveFocusForward: () -> Void
    let onMoveFocusBackward: () -> Void
    let onFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onBeginEditing: onBeginEditing,
            onTextChange: onTextChange,
            onSelectionChange: onSelectionChange,
            onFocus: onFocus
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let textView = NVEditorTextView()
        textView.isRichText = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.allowsUndo = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 18, height: 18)
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.font = NSFont(name: fontName, size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.backgroundColor = backgroundColor
        textView.insertionPointColor = foregroundColor
        textView.typingAttributes[.foregroundColor] = foregroundColor
        textView.usesSoftTabs = usesSoftTabs
        textView.tabWidth = tabWidth
        textView.noteID = noteID
        textView.onUndoCommand = onUndoCommand
        textView.onRedoCommand = onRedoCommand
        textView.onMoveToTitleEditing = onMoveToTitleEditing
        textView.onMoveToTagEditing = onMoveToTagEditing
        textView.onMoveFocusForward = onMoveFocusForward
        textView.onMoveFocusBackward = onMoveFocusBackward
        NVEditorTextView.setDefaultPlainTextAttributes([
            .font: textView.font as Any,
            .foregroundColor: foregroundColor
        ])
        textView.textStorage?.setAttributedString(attributedText)
        textView.setSelectedRange(selection)
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.currentNoteID = noteID
        NVEditorTextView.setActiveTextView(textView)
        NVEditorTextView.setCurrentSelectedNoteID(noteID)
        context.coordinator.applySearchHighlights(
            to: textView,
            terms: searchHighlightTerms,
            color: searchHighlightColor
        )
        context.coordinator.lastHandledFocusRequestID = focusRequestID
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        let desiredFont = NSFont(name: fontName, size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if textView.font != desiredFont {
            textView.font = desiredFont
        }
        if textView.backgroundColor != backgroundColor {
            textView.backgroundColor = backgroundColor
        }
        if textView.insertionPointColor != foregroundColor {
            textView.insertionPointColor = foregroundColor
        }
        textView.typingAttributes[.foregroundColor] = foregroundColor
        textView.usesSoftTabs = usesSoftTabs
        textView.tabWidth = tabWidth
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }

        let noteChanged = context.coordinator.currentNoteID != noteID
        context.coordinator.currentNoteID = noteID
        textView.noteID = noteID
        textView.onUndoCommand = onUndoCommand
        textView.onRedoCommand = onRedoCommand
        textView.onMoveToTitleEditing = onMoveToTitleEditing
        textView.onMoveToTagEditing = onMoveToTagEditing
        textView.onMoveFocusForward = onMoveFocusForward
        textView.onMoveFocusBackward = onMoveFocusBackward
        NVEditorTextView.setDefaultPlainTextAttributes([
            .font: desiredFont,
            .foregroundColor: foregroundColor
        ])
        let isEditingThisView = textView.window?.firstResponder === textView
        let forcedRefresh = context.coordinator.lastRefreshGeneration != refreshGeneration
        context.coordinator.lastRefreshGeneration = refreshGeneration
        NVEditorTextView.setActiveTextView(textView)
        NVEditorTextView.setCurrentSelectedNoteID(noteID)

        if noteChanged || forcedRefresh || (!isEditingThisView && !textView.attributedString().isEqual(to: attributedText)) {
            context.coordinator.isPerformingProgrammaticUpdate = true
            textView.textStorage?.setAttributedString(attributedText)
            context.coordinator.isPerformingProgrammaticUpdate = false
        }

        if noteChanged || forcedRefresh || (!isEditingThisView && textView.selectedRange() != selection) {
            context.coordinator.isPerformingProgrammaticUpdate = true
            textView.setSelectedRange(selection)
            context.coordinator.isPerformingProgrammaticUpdate = false
        }

        context.coordinator.applySearchHighlights(
            to: textView,
            terms: searchHighlightTerms,
            color: searchHighlightColor
        )

        if context.coordinator.lastHandledFocusRequestID != focusRequestID {
            context.coordinator.lastHandledFocusRequestID = focusRequestID
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, AppKitNoteTextViewFormattingDelegate {
        weak var textView: NVEditorTextView?
        private let onBeginEditing: () -> Void
        private let onTextChange: (NSAttributedString, NSRange) -> Void
        private let onSelectionChange: (NSRange) -> Void
        private let onFocus: () -> Void
        var isPerformingProgrammaticUpdate = false
        var currentNoteID: UUID?
        var lastRefreshGeneration: Int = 0
        var lastHandledFocusRequestID: Int = 0

        init(
            onBeginEditing: @escaping () -> Void,
            onTextChange: @escaping (NSAttributedString, NSRange) -> Void,
            onSelectionChange: @escaping (NSRange) -> Void,
            onFocus: @escaping () -> Void
        ) {
            self.onBeginEditing = onBeginEditing
            self.onTextChange = onTextChange
            self.onSelectionChange = onSelectionChange
            self.onFocus = onFocus
        }

        func textDidBeginEditing(_ notification: Notification) {
            onFocus()
            onBeginEditing()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, !isPerformingProgrammaticUpdate else { return }
            onTextChange(NSAttributedString(attributedString: textView.attributedString()), textView.selectedRange())
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, !isPerformingProgrammaticUpdate else { return }
            onSelectionChange(textView.selectedRange())
        }

        func noteTextViewDidApplyFormatting(_ textView: NSTextView) {
            guard !isPerformingProgrammaticUpdate else { return }
            onTextChange(NSAttributedString(attributedString: textView.attributedString()), textView.selectedRange())
        }

        func applySearchHighlights(to textView: NSTextView, terms: [String], color: NSColor) {
            guard let layoutManager = textView.layoutManager else { return }

            let fullRange = NSRange(location: 0, length: textView.string.utf16.count)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)

            guard !terms.isEmpty, fullRange.length > 0 else { return }

            let nsString = textView.string as NSString
            for term in terms {
                let trimmedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedTerm.isEmpty else { continue }

                var searchRange = NSRange(location: 0, length: nsString.length)
                while true {
                    let foundRange = nsString.range(
                        of: trimmedTerm,
                        options: [.caseInsensitive, .diacriticInsensitive],
                        range: searchRange
                    )
                    if foundRange.location == NSNotFound {
                        break
                    }

                    layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: foundRange)

                    let nextLocation = foundRange.location + foundRange.length
                    if nextLocation >= nsString.length {
                        break
                    }
                    searchRange = NSRange(location: nextLocation, length: nsString.length - nextLocation)
                }
            }
        }
    }
}
