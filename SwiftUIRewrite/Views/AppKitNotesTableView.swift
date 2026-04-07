import AppKit
import SwiftUI

final class NVNotesTableView: NSTableView {
    private static weak var activeTableView: NVNotesTableView?
    private static let allTables = NSHashTable<NVNotesTableView>.weakObjects()

    var onMoveForward: (() -> Void)?
    var onMoveBackward: (() -> Void)?
    var onFocusChange: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            Self.activeTableView = self
            onFocusChange?()
        }
        return accepted
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Self.allTables.add(self)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let characters = event.charactersIgnoringModifiers else {
            super.keyDown(with: event)
            return
        }

        if characters == "\t" {
            if modifiers.contains(.shift) {
                onMoveBackward?()
            } else {
                onMoveForward?()
            }
            return
        }
        if characters == String(Character(UnicodeScalar(NSBackTabCharacter)!)) {
            onMoveBackward?()
            return
        }

        super.keyDown(with: event)
    }

    static func focusActiveTable(selectFirstRowIfNeeded: Bool = true) {
        let candidates = allTables.allObjects
        let preferredTable =
            activeTableView ??
            candidates.first(where: { $0.window?.isKeyWindow == true }) ??
            candidates.first(where: { $0.window?.isMainWindow == true }) ??
            candidates.first

        guard let preferredTable else { return }
        preferredTable.window?.makeFirstResponder(preferredTable)
        if selectFirstRowIfNeeded, preferredTable.selectedRow == -1, preferredTable.numberOfRows > 0 {
            preferredTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            preferredTable.scrollRowToVisible(0)
        }
        activeTableView = preferredTable
    }
}

struct AppKitNotesTableView: NSViewRepresentable {
    let notes: [Note]
    let selectedNoteID: UUID?
    let showsPreviewInTitleColumn: Bool
    let tableTitleFontSize: CGFloat
    let tablePreviewFontSize: CGFloat
    let tableMetadataFontSize: CGFloat
    let refreshGeneration: Int
    let focusRequestID: Int
    let selectFirstRowOnFocusRequest: Bool
    let sortField: NoteSortField
    let sortReversed: Bool
    let onSelectNote: (UUID?) -> Void
    let onSort: (NoteSortField) -> Void
    let onMoveForward: () -> Void
    let onMoveBackward: () -> Void
    let onFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            showsPreviewInTitleColumn: showsPreviewInTitleColumn,
            tableTitleFontSize: tableTitleFontSize,
            tablePreviewFontSize: tablePreviewFontSize,
            tableMetadataFontSize: tableMetadataFontSize,
            onSelectNote: onSelectNote,
            onSort: onSort,
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
        scrollView.backgroundColor = .textBackgroundColor

        let tableView = NVNotesTableView()
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = false
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = false
        tableView.allowsEmptySelection = true
        tableView.rowHeight = showsPreviewInTitleColumn ? 30 : 19
        tableView.intercellSpacing = NSSize(width: 2, height: 0)
        tableView.focusRingType = .none
        tableView.style = .plain
        tableView.backgroundColor = .textBackgroundColor
        tableView.gridStyleMask = []
        tableView.selectionHighlightStyle = .regular
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.target = context.coordinator
        tableView.action = #selector(Coordinator.didActivateRow(_:))
        tableView.onMoveForward = onMoveForward
        tableView.onMoveBackward = onMoveBackward
        tableView.onFocusChange = onFocus

        let titleColumn = makeColumn(id: .title, title: "Title", minWidth: 220, width: 320)
        let labelsColumn = makeColumn(id: .labels, title: "Labels", minWidth: 90, width: 120)
        let modifiedColumn = makeColumn(id: .modified, title: "Modified", minWidth: 90, width: 110)
        let createdColumn = makeColumn(id: .created, title: "Created", minWidth: 90, width: 110)

        [titleColumn, labelsColumn, modifiedColumn, createdColumn].forEach(tableView.addTableColumn(_:))
        context.coordinator.isApplyingProgrammaticSort = true
        tableView.sortDescriptors = sortDescriptors(field: sortField, reversed: sortReversed)
        context.coordinator.isApplyingProgrammaticSort = false

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        context.coordinator.notes = notes
        context.coordinator.focusRequestID = focusRequestID
        context.coordinator.selectFirstRowOnFocusRequest = selectFirstRowOnFocusRequest
        context.coordinator.lastHandledFocusRequestID = focusRequestID
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = context.coordinator.tableView as? NVNotesTableView else { return }
        context.coordinator.notes = notes
        context.coordinator.showsPreviewInTitleColumn = showsPreviewInTitleColumn
        context.coordinator.tableTitleFontSize = tableTitleFontSize
        context.coordinator.tablePreviewFontSize = tablePreviewFontSize
        context.coordinator.tableMetadataFontSize = tableMetadataFontSize
        context.coordinator.focusRequestID = focusRequestID
        context.coordinator.selectFirstRowOnFocusRequest = selectFirstRowOnFocusRequest
        tableView.onMoveForward = onMoveForward
        tableView.onMoveBackward = onMoveBackward
        tableView.onFocusChange = onFocus
        tableView.rowHeight = showsPreviewInTitleColumn ? 30 : 19
        let desiredSort = sortDescriptors(field: sortField, reversed: sortReversed)
        if tableView.sortDescriptors != desiredSort {
            context.coordinator.isApplyingProgrammaticSort = true
            tableView.sortDescriptors = desiredSort
            context.coordinator.isApplyingProgrammaticSort = false
        }
        tableView.reloadData()

        let selectedRow = selectedNoteID.flatMap { id in notes.firstIndex(where: { $0.id == id }) } ?? -1
        if tableView.selectedRow != selectedRow {
            context.coordinator.isApplyingProgrammaticSelection = true
            if selectedRow >= 0 {
                tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
                tableView.scrollRowToVisible(selectedRow)
            } else {
                tableView.deselectAll(nil)
            }
            context.coordinator.isApplyingProgrammaticSelection = false
        }

        if context.coordinator.lastRefreshGeneration != refreshGeneration {
            context.coordinator.lastRefreshGeneration = refreshGeneration
            let allColumns = IndexSet(integersIn: 0..<tableView.numberOfColumns)
            let allRows = IndexSet(integersIn: 0..<tableView.numberOfRows)
            tableView.reloadData(forRowIndexes: allRows, columnIndexes: allColumns)
        }

        if context.coordinator.lastHandledFocusRequestID != focusRequestID {
            context.coordinator.lastHandledFocusRequestID = focusRequestID
            DispatchQueue.main.async {
                NVNotesTableView.focusActiveTable(selectFirstRowIfNeeded: selectFirstRowOnFocusRequest)
            }
        }
    }

    private func makeColumn(id: NoteSortField, title: String, minWidth: CGFloat, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id.rawValue))
        column.title = title
        column.minWidth = minWidth
        column.width = width
        column.resizingMask = .autoresizingMask
        column.sortDescriptorPrototype = NSSortDescriptor(key: id.rawValue, ascending: true)
        let headerCell = NVTableHeaderCell(textCell: title)
        headerCell.alignment = .left
        column.headerCell = headerCell
        return column
    }

    private func sortDescriptors(field: NoteSortField, reversed: Bool) -> [NSSortDescriptor] {
        [NSSortDescriptor(key: field.rawValue, ascending: !reversed)]
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var tableView: NSTableView?
        var notes: [Note] = []
        var showsPreviewInTitleColumn: Bool
        var tableTitleFontSize: CGFloat
        var tablePreviewFontSize: CGFloat
        var tableMetadataFontSize: CGFloat
        var lastRefreshGeneration: Int = 0

        private let onSelectNote: (UUID?) -> Void
        private let onSort: (NoteSortField) -> Void
        private let onFocus: () -> Void
        var isApplyingProgrammaticSort = false
        var isApplyingProgrammaticSelection = false
        var focusRequestID = 0
        var selectFirstRowOnFocusRequest = true
        var lastHandledFocusRequestID = 0
        private lazy var dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .none
            return formatter
        }()

        init(
            showsPreviewInTitleColumn: Bool,
            tableTitleFontSize: CGFloat,
            tablePreviewFontSize: CGFloat,
            tableMetadataFontSize: CGFloat,
            onSelectNote: @escaping (UUID?) -> Void,
            onSort: @escaping (NoteSortField) -> Void,
            onFocus: @escaping () -> Void
        ) {
            self.showsPreviewInTitleColumn = showsPreviewInTitleColumn
            self.tableTitleFontSize = tableTitleFontSize
            self.tablePreviewFontSize = tablePreviewFontSize
            self.tableMetadataFontSize = tableMetadataFontSize
            self.onSelectNote = onSelectNote
            self.onSort = onSort
            self.onFocus = onFocus
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            notes.count
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingProgrammaticSelection else { return }
            guard let tableView else { return }
            let row = tableView.selectedRow
            onSelectNote(row >= 0 && row < notes.count ? notes[row].id : nil)
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isApplyingProgrammaticSort else { return }
            guard let key = tableView.sortDescriptors.first?.key,
                  let field = NoteSortField(rawValue: key) else {
                return
            }
            onSort(field)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn else { return nil }
            let note = notes[row]
            let identifier = tableColumn.identifier

            if identifier.rawValue == NoteSortField.title.rawValue {
                return titleCell(for: note, identifier: identifier)
            }

            let text: String
            switch identifier.rawValue {
            case NoteSortField.labels.rawValue:
                text = note.labelsText
            case NoteSortField.modified.rawValue:
                text = dateFormatter.string(from: note.modifiedAt)
            case NoteSortField.created.rawValue:
                text = dateFormatter.string(from: note.createdAt)
            default:
                text = ""
            }
            return textCell(text: text, identifier: identifier)
        }

        @objc
        func didActivateRow(_ sender: Any?) {
            // Keep row activation passive; selection change drives state updates.
        }

        private func titleCell(for note: Note, identifier: NSUserInterfaceItemIdentifier) -> NSView {
            let cell = NSTableCellView()
            cell.identifier = identifier

            let titleField = NSTextField(labelWithString: note.title)
            titleField.font = NSFont.systemFont(ofSize: max(11, tableTitleFontSize), weight: .medium)
            titleField.lineBreakMode = .byTruncatingTail

            let previewText = showsPreviewInTitleColumn && !note.preview.isEmpty ? note.preview : ""
            let previewField = NSTextField(labelWithString: previewText)
            previewField.font = NSFont.systemFont(ofSize: max(9, tablePreviewFontSize))
            previewField.textColor = .secondaryLabelColor
            previewField.lineBreakMode = .byTruncatingTail
            previewField.isHidden = previewText.isEmpty

            let stack = NSStackView(views: [titleField, previewField])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 1
            stack.translatesAutoresizingMaskIntoConstraints = false

            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        private func textCell(text: String, identifier: NSUserInterfaceItemIdentifier) -> NSView {
            let cell = NSTableCellView()
            cell.identifier = identifier

            let field = NSTextField(labelWithString: text)
            field.font = NSFont.systemFont(ofSize: max(9.5, tableMetadataFontSize))
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false

            cell.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
    }
}

private final class NVTableHeaderCell: NSTableHeaderCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let title = NSAttributedString(string: stringValue, attributes: attributes)
        let drawRect = cellFrame.insetBy(dx: 6, dy: 2)
        title.draw(in: drawRect)
    }
}
