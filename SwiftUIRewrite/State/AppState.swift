import AppKit
import Carbon.HIToolbox
import Foundation

private enum NewNoteStorageFormat {
    static let plainText = "Plain Text (.txt)"
    static let richText = "Rich Text (.rtf)"
    static let html = "HTML (.html)"
    static let markdown = "Markdown (.md)"

    static func fileExtension(for displayName: String) -> String {
        switch displayName {
        case richText:
            return "rtf"
        case html:
            return "html"
        case markdown:
            return "md"
        default:
            return "txt"
        }
    }
}

private final class GlobalHotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var callback: (() -> Void)?

    func register(hotKey: ActivationHotKey, callback: @escaping () -> Void) -> Bool {
        unregister()
        guard hotKey.isEnabled else { return true }

        self.callback = callback

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                if hotKeyID.id == 1 {
                    manager.callback?()
                }
                return noErr
            },
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandlerRef
        )

        guard handlerStatus == noErr else { return false }

        let hotKeyID = EventHotKeyID(signature: fourCharCode("NVRW"), id: 1)
        let modifierFlags = carbonModifierFlags(from: hotKey.modifierFlags)
        let registerStatus = RegisterEventHotKey(
            UInt32(hotKey.keyCode),
            modifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus != noErr {
            unregister()
            return false
        }

        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        callback = nil
    }

    private func carbonModifierFlags(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbonFlags: UInt32 = 0
        if flags.contains(.command) { carbonFlags |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonFlags |= UInt32(optionKey) }
        if flags.contains(.control) { carbonFlags |= UInt32(controlKey) }
        if flags.contains(.shift) { carbonFlags |= UInt32(shiftKey) }
        return carbonFlags
    }

    private func fourCharCode(_ string: String) -> OSType {
        string.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }
}

private final class HotKeyRecorderView: NSView {
    var onRecord: ((UInt16, NSEvent.ModifierFlags) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard !modifiers.isEmpty else { return }

        switch event.keyCode {
        case 54, 55, 56, 57, 58, 59, 60, 61, 62, 63:
            return
        default:
            break
        }

        onRecord?(event.keyCode, modifiers)
    }
}

private enum HotKeyRecorder {
    static func prompt(currentHotKey: ActivationHotKey, title: String, message: String) -> ActivationHotKey? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Use Shortcut")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 84))
        let instructionLabel = NSTextField(labelWithString: "Current: \(currentHotKey.displayString)")
        instructionLabel.frame = NSRect(x: 0, y: 56, width: 340, height: 20)
        instructionLabel.textColor = .secondaryLabelColor

        let previewLabel = NSTextField(labelWithString: "Press a shortcut with Command, Option, Control, or Shift.")
        previewLabel.frame = NSRect(x: 0, y: 30, width: 340, height: 20)

        let recorderView = HotKeyRecorderView(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        recorderView.wantsLayer = true
        recorderView.layer?.cornerRadius = 6
        recorderView.layer?.borderWidth = 1
        recorderView.layer?.borderColor = NSColor.separatorColor.cgColor
        recorderView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        var recordedKeyCode = currentHotKey.keyCode
        var recordedModifiers = currentHotKey.modifierFlags
        recorderView.onRecord = { keyCode, modifiers in
            recordedKeyCode = keyCode
            recordedModifiers = modifiers
            let preview = ActivationHotKey(
                isEnabled: true,
                keyCode: keyCode,
                modifierFlagsRawValue: modifiers.rawValue
            )
            previewLabel.stringValue = "Recorded: \(preview.displayString)"
        }

        container.addSubview(instructionLabel)
        container.addSubview(previewLabel)
        container.addSubview(recorderView)
        alert.accessoryView = container

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        return ActivationHotKey(
            isEnabled: true,
            keyCode: recordedKeyCode,
            modifierFlagsRawValue: recordedModifiers.rawValue
        )
    }
}

@MainActor
final class AppState: ObservableObject {
    private struct LegacyPassphraseDialogResult {
        var passphraseData: Data
        var rememberInKeychain: Bool
        var hashIterationCount: Int
        var keyLengthInBits: Int
        var currentPassphraseData: Data?
    }

    private enum AppUndoOperation {
        case created(Note)
        case deleted(notes: [Note], previouslySelectedNoteID: UUID?)
        case bookmarkAdded(NoteBookmark)
        case bookmarkRemoved(NoteBookmark)
        case savedSearchAdded(SavedSearchItem)
        case savedSearchUpdated(old: SavedSearchItem, new: SavedSearchItem)
        case savedSearchRemoved(SavedSearchItem)
        case layoutChanged(from: LayoutStyle, to: LayoutStyle)
    }

    private struct NoteRevision {
        var title: String
        var body: NSAttributedString
        var labels: [String]
        var selectedRange: NSRange
    }

    private struct NoteUndoHistory {
        var undoStack: [NoteRevision] = []
        var redoStack: [NoteRevision] = []
        var lastRegisteredAt: Date?
    }

    @Published private(set) var notes: [Note] = []
    @Published private(set) var filteredNotes: [Note] = []
    @Published private(set) var tags: [TagItem] = []
    @Published private(set) var bookmarks: [NoteBookmark] = []
    @Published private(set) var savedSearches: [SavedSearchItem] = []
    @Published private(set) var syncStates: [SyncServiceState] = []
    @Published var preferences = NVPreferences() {
        didSet {
            guard hasLoadedInitialState, !isApplyingInternalPreferencesChange else { return }
            repository.savePreferences(preferences)
            rebuildDerivedCollections()
            syncDirectoryMonitoring()
            syncGlobalHotKeyRegistration()
        }
    }
    @Published var searchText = "" {
        didSet {
            guard hasLoadedInitialState else { return }
            saveUIState()
        }
    }
    @Published var selectedNoteID: UUID? {
        didSet {
            guard hasLoadedInitialState else { return }
            saveUIState()
        }
    }
    @Published var selectedNoteIDs = Set<UUID>()
    @Published var selectedTag: String? {
        didSet {
            guard hasLoadedInitialState else { return }
            saveUIState()
        }
    }
    @Published var sidebarMode: SidebarMode = .notes {
        didSet {
            guard hasLoadedInitialState else { return }
            saveUIState()
        }
    }
    @Published var editorSelection = EditorSelection(range: NSRange(location: 0, length: 0))
    @Published var isShowingDeletionConfirmation = false
    @Published var pendingDeletionIDs = Set<UUID>()
    @Published private(set) var editorRefreshGeneration = 0
    @Published private(set) var browserRefreshGeneration = 0
    @Published var sortOrder: [KeyPathComparator<Note>] = [] {
        didSet {
            guard hasLoadedInitialState else { return }
            syncPreferencesFromSortOrder()
            rebuildDerivedCollections()
        }
    }

    private let repository: NoteRepository
    private let directoryMonitor = DirectoryMonitor()
    private let globalHotKeyManager = GlobalHotKeyManager()
    private var cachedTypedSearch: String?
    private var pendingDirectoryReloadWorkItem: DispatchWorkItem?
    private var suppressDirectoryRefreshUntil = Date.distantPast
    private var isApplyingInternalPreferencesChange = false
    private var hasLoadedInitialState = false
    private var cachedLegacyDatabasePassphraseData: Data?
    private var noteHistories: [UUID: NoteUndoHistory] = [:]
    private var appUndoStack: [AppUndoOperation] = []
    private var appRedoStack: [AppUndoOperation] = []

    init(repository: NoteRepository) {
        self.repository = repository
        self.preferences = repository.preferences
        self.searchText = repository.searchText
        self.selectedNoteID = repository.selectedNoteID
        self.selectedTag = repository.selectedTag
        self.sidebarMode = repository.sidebarMode
        self.sortOrder = Self.sortOrder(for: repository.preferences)
        self.refreshLegacyStorageStatus()
        reloadFromRepository()
        syncDirectoryMonitoring()
        syncGlobalHotKeyRegistration()
        hasLoadedInitialState = true
    }

    var selectedNote: Note? {
        guard let selectedNoteID else { return nil }
        return notes.first(where: { $0.id == selectedNoteID })
    }

    var titleForWindow: String {
        selectedNote?.title ?? "Notation"
    }

    var controlFieldText: String {
        return searchText
    }

    var shouldSelectAllControlFieldTextOnFocus: Bool {
        searchText.isEmpty && selectedNote != nil
    }

    var isFiltering: Bool {
        !searchText.isEmpty || selectedTag != nil
    }

    var isCurrentBackendReadOnly: Bool {
        false
    }

    var canRepairSelectedNoteEncoding: Bool {
        guard preferences.legacyStorage.backend == .legacyFileDirectory,
              let selectedNote else {
            return false
        }
        let adapter = LegacyDirectoryStorageAdapter()
        return adapter.supportsEncodingRepair(for: selectedNote)
    }

    var selectedNoteSupportsFormatting: Bool {
        guard let selectedNote else { return false }

        if preferences.legacyStorage.backend == .legacyFileDirectory {
            let pathExtension = selectedNote.fileURL?.pathExtension.lowercased()
                ?? selectedNote.syncMetadata["storageExtension"]?.lowercased()
                ?? NewNoteStorageFormat.fileExtension(for: preferences.noteStorageFormat)
            return pathExtension == "rtf" || pathExtension == "html" || pathExtension == "htm"
        }

        return true
    }

    var canRecoverLegacySingleDatabase: Bool {
        guard preferences.legacyStorage.backend == .legacySingleDatabase,
              let directoryURL = resolvedNotesDirectoryURL() else {
            return false
        }
        let adapter = LegacySingleDatabaseStorageAdapter()
        return adapter.backupExists(at: directoryURL.path)
    }

    var canRecoverLegacySingleDatabaseJournal: Bool {
        guard preferences.legacyStorage.backend == .legacySingleDatabase,
              let directoryURL = resolvedNotesDirectoryURL() else {
            return false
        }
        let adapter = LegacySingleDatabaseStorageAdapter()
        return adapter.journalExists(at: directoryURL.path)
    }

    var canCommitRecoveredLegacySingleDatabase: Bool {
        guard preferences.legacyStorage.backend == .legacySingleDatabase,
              let source = preferences.legacyStorage.lastRecoverySource else {
            return false
        }
        return source != .database
    }

    var canConfigureLegacyDatabaseEncryption: Bool {
        preferences.legacyStorage.backend == .legacySingleDatabase
    }

    var hasLegacyDatabasePassphraseInKeychain: Bool {
        guard let identifier = preferences.legacyStorage.keychainDatabaseIdentifier else {
            return false
        }
        return LegacyEncryptionSupport.keychainPassphraseData(identifier: identifier) != nil
    }

    var activationHotKeyDisplayString: String {
        preferences.activationHotKey.displayString
    }

    var canUndoCurrentNote: Bool {
        if let selectedNoteID, !(noteHistories[selectedNoteID]?.undoStack.isEmpty ?? true) {
            return true
        }
        return !appUndoStack.isEmpty
    }

    var canRedoCurrentNote: Bool {
        if let selectedNoteID, !(noteHistories[selectedNoteID]?.redoStack.isEmpty ?? true) {
            return true
        }
        return !appRedoStack.isEmpty
    }

    func reloadFromRepository() {
        notes = repository.notes
        bookmarks = repository.bookmarks
        savedSearches = repository.savedSearches
        syncStates = repository.syncStates
        preferences = repository.preferences
        rebuildDerivedCollections()
        syncDirectoryMonitoring()
    }

    func rebuildDerivedCollections() {
        let counts = Dictionary(notes.flatMap(\.labels).map { ($0, 1) }, uniquingKeysWith: +)
        tags = counts
            .map { TagItem(id: UUID(), name: $0.key, noteCount: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        filteredNotes = notes
            .filter { $0.matches(searchText: searchText, tagFilter: selectedTag) }
            .sorted(by: noteSortComparator)

        if let selectedNoteID, !filteredNotes.contains(where: { $0.id == selectedNoteID }) {
            self.selectedNoteID = nil
        }
    }

    var preferredSelectedNote: Note? {
        filteredNotes.first
    }

    var activeSearchHighlightTerms: [String] {
        guard preferences.highlightsSearchTerms,
              selectedNote != nil else {
            return []
        }

        return parsedSearchTerms(from: searchText)
    }

    func updateSearch(_ value: String) {
        searchText = value
        rebuildDerivedCollections()
    }

    func updateControlField(_ value: String) {
        updateSearch(value)
    }

    func autoCompleteControlField(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard preferences.autoCompleteSearches, !normalized.isEmpty else { return nil }

        return notes
            .map(\.title)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .first { title in
                title.count > normalized.count &&
                title.range(of: normalized, options: [.caseInsensitive, .anchored]) != nil
            }
    }

    func clearSearch() {
        cachedTypedSearch = nil
        searchText = ""
        selectedTag = nil
        selectedNoteID = nil
        selectedNoteIDs.removeAll()
        rebuildDerivedCollections()
    }

    func select(noteID: UUID?, cacheSearch: Bool = true) {
        let newSelectionSet: Set<UUID> = noteID.map { [$0] } ?? []
        if selectedNoteID == noteID && selectedNoteIDs == newSelectionSet {
            return
        }

        if cacheSearch, let noteID, selectedNoteID != noteID {
            cachedTypedSearch = searchText
        }

        selectedNoteID = noteID
        selectedNoteIDs = newSelectionSet
    }

    func select(tag: String?) {
        selectedTag = tag
        sidebarMode = .tags
        rebuildDerivedCollections()
    }

    func select(savedSearch: SavedSearchItem) {
        sidebarMode = .savedSearches
        searchText = savedSearch.query
        rebuildDerivedCollections()
        if let selectedNoteID = savedSearch.selectedNoteID {
            select(noteID: selectedNoteID, cacheSearch: false)
        }
    }

    func restore(bookmark: NoteBookmark) {
        sidebarMode = .bookmarks
        searchText = bookmark.searchString
        rebuildDerivedCollections()
        select(noteID: bookmark.noteID, cacheSearch: false)
    }

    @discardableResult
    func createNoteIfNecessary() -> Note {
        if isCurrentBackendReadOnly {
            preferences.legacyStorage.lastLoadSummary = "Read-only backend"
            preferences.legacyStorage.lastLoadDetail = "Legacy single-database mode is currently read-only in the rewrite."
            return selectedNote ?? Note(title: "Read Only", body: NSAttributedString(string: ""))
        }

        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let selectedNote, (trimmedSearch.isEmpty || selectedNote.title.caseInsensitiveCompare(trimmedSearch) == .orderedSame) {
            return selectedNote
        }

        if let exactMatch = notes.first(where: { $0.title.caseInsensitiveCompare(trimmedSearch) == .orderedSame }) {
            select(noteID: exactMatch.id, cacheSearch: false)
            return exactMatch
        }

        let title = trimmedSearch.isEmpty ? "Untitled Note" : trimmedSearch
        let font = NSFont(name: preferences.noteBodyFontName, size: preferences.noteBodyFontSize)
            ?? NSFont.monospacedSystemFont(ofSize: preferences.noteBodyFontSize, weight: .regular)
        let body = NSAttributedString(string: "", attributes: [.font: font, .foregroundColor: NSColor.textColor])
        var note = Note(title: title, body: body)
        if preferences.legacyStorage.backend == .legacyFileDirectory {
            note.syncMetadata["storageExtension"] = NewNoteStorageFormat.fileExtension(for: preferences.noteStorageFormat)
        } else if preferences.legacyStorage.backend == .legacySingleDatabase {
            note.syncMetadata["storageBackend"] = "legacySingleDatabase"
        }
        note.selectedRange = NSRange(location: 0, length: 0)
        repository.upsert(note)
        upsertLocal(note)
        select(noteID: note.id, cacheSearch: false)
        syncAllNotesToActiveStorage()
        registerAppUndoOperation(.created(note))
        return note
    }

    func updateCurrentNoteBody(_ body: NSAttributedString, selectedRange: NSRange) {
        guard !isCurrentBackendReadOnly else { return }
        guard var note = selectedNote else {
            return
        }
        let copiedBody = NSAttributedString(attributedString: body)
        guard !note.body.isEqual(to: copiedBody) || note.selectedRange != selectedRange else {
            return
        }
        registerUndoRevision(for: note, coalescing: true)
        note.body = copiedBody
        note.plainBody = copiedBody.string
        note.modifiedAt = .now
        note.selectedRange = selectedRange
        repository.upsert(note)
        upsertLocal(note)
        syncAllNotesToActiveStorage()
        selectedNoteID = note.id
        browserRefreshGeneration &+= 1
    }

    func updateCurrentNoteSelection(_ selectedRange: NSRange) {
        guard let selectedNoteID, let index = notes.firstIndex(where: { $0.id == selectedNoteID }) else {
            return
        }
        notes[index].selectedRange = selectedRange
        if let filteredIndex = filteredNotes.firstIndex(where: { $0.id == selectedNoteID }) {
            filteredNotes[filteredIndex].selectedRange = selectedRange
        }
    }

    func undoCurrentNote() {
        if let currentSelectedNoteID = selectedNoteID,
           let history = noteHistories[currentSelectedNoteID],
           !history.undoStack.isEmpty {
            undoSelectedNoteRevision(currentSelectedNoteID)
            return
        }

        guard let operation = appUndoStack.popLast() else { return }
        applyUndoOperation(operation)
    }

    func redoCurrentNote() {
        if let currentSelectedNoteID = selectedNoteID,
           let history = noteHistories[currentSelectedNoteID],
           !history.redoStack.isEmpty {
            redoSelectedNoteRevision(currentSelectedNoteID)
            return
        }

        guard let operation = appRedoStack.popLast() else { return }
        applyRedoOperation(operation)
    }

    private func undoSelectedNoteRevision(_ currentSelectedNoteID: UUID) {
        guard selectedNoteID == currentSelectedNoteID,
              var note = selectedNote,
              var history = noteHistories[currentSelectedNoteID],
              let revision = history.undoStack.popLast() else {
            return
        }

        history.redoStack.append(NoteRevision(
            title: note.title,
            body: NSAttributedString(attributedString: note.body),
            labels: note.labels,
            selectedRange: note.selectedRange
        ))
        history.lastRegisteredAt = nil
        noteHistories[currentSelectedNoteID] = history

        note.title = revision.title
        note.body = NSAttributedString(attributedString: revision.body)
        note.plainBody = revision.body.string
        note.labels = revision.labels
        note.selectedRange = revision.selectedRange
        note.modifiedAt = .now
        repository.upsert(note)
        upsertLocal(note)
        selectedNoteID = note.id
        syncAllNotesToActiveStorage()
        editorRefreshGeneration &+= 1
        browserRefreshGeneration &+= 1
    }

    private func redoSelectedNoteRevision(_ currentSelectedNoteID: UUID) {
        guard selectedNoteID == currentSelectedNoteID,
              var note = selectedNote,
              var history = noteHistories[currentSelectedNoteID],
              let revision = history.redoStack.popLast() else {
            return
        }

        history.undoStack.append(NoteRevision(
            title: note.title,
            body: NSAttributedString(attributedString: note.body),
            labels: note.labels,
            selectedRange: note.selectedRange
        ))
        history.lastRegisteredAt = nil
        noteHistories[currentSelectedNoteID] = history

        note.title = revision.title
        note.body = NSAttributedString(attributedString: revision.body)
        note.plainBody = revision.body.string
        note.labels = revision.labels
        note.selectedRange = revision.selectedRange
        note.modifiedAt = .now
        repository.upsert(note)
        upsertLocal(note)
        selectedNoteID = note.id
        syncAllNotesToActiveStorage()
        editorRefreshGeneration &+= 1
        browserRefreshGeneration &+= 1
    }

    func renameCurrentNote(_ title: String, updateSearchField: Bool = false) {
        guard !isCurrentBackendReadOnly else { return }
        guard var note = selectedNote else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard note.title != trimmed else { return }
        registerUndoRevision(for: note, coalescing: false)
        note.title = trimmed
        note.modifiedAt = .now
        repository.upsert(note)
        upsertLocal(note)
        syncAllNotesToActiveStorage()
        selectedNoteID = note.id
        if updateSearchField {
            searchText = trimmed
        }
    }

    func updateLabelsForCurrentNote(_ value: String) {
        guard !isCurrentBackendReadOnly else { return }
        guard var note = selectedNote else { return }
        let updatedLabels = value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard note.labels != updatedLabels else { return }
        registerUndoRevision(for: note, coalescing: false)
        note.labels = updatedLabels
        note.modifiedAt = .now
        repository.upsert(note)
        upsertLocal(note)
        syncAllNotesToActiveStorage()
        selectedNoteID = note.id
    }

    func requestDeleteSelectedNotes() {
        guard !isCurrentBackendReadOnly else { return }
        pendingDeletionIDs = selectedNoteIDs
        isShowingDeletionConfirmation = preferences.confirmDeletion && !pendingDeletionIDs.isEmpty
        if !preferences.confirmDeletion {
            deletePendingNotes()
        }
    }

    func deletePendingNotes() {
        guard !pendingDeletionIDs.isEmpty else { return }
        let notesToDelete = notes.filter { pendingDeletionIDs.contains($0.id) }
        let previousSelection = selectedNoteID
        if preferences.legacyStorage.backend == .legacyFileDirectory {
            let adapter = LegacyDirectoryStorageAdapter()
            notesToDelete.forEach { adapter.removeNote($0) }
        }
        repository.remove(noteIDs: pendingDeletionIDs)
        let deletedSelection = pendingDeletionIDs
        pendingDeletionIDs.removeAll()
        isShowingDeletionConfirmation = false
        reloadFromRepository()
        syncAllNotesToActiveStorage()
        if let selectedNoteID, deletedSelection.contains(selectedNoteID) {
            self.selectedNoteID = filteredNotes.first?.id
        }
        selectedNoteIDs = selectedNoteID.map { [$0] } ?? []
        registerAppUndoOperation(.deleted(notes: notesToDelete, previouslySelectedNoteID: previousSelection))
        editorRefreshGeneration &+= 1
        browserRefreshGeneration &+= 1
    }

    func cancelPendingDeletion() {
        pendingDeletionIDs.removeAll()
        isShowingDeletionConfirmation = false
    }

    func addBookmarkForSelection() {
        guard let selectedNote else { return }
        let previousBookmarks = bookmarks
        repository.addBookmark(for: selectedNote, searchString: searchText)
        bookmarks = repository.bookmarks
        if let addedBookmark = bookmarks.first(where: { bookmark in
            !previousBookmarks.contains(where: { $0.id == bookmark.id })
        }) {
            registerAppUndoOperation(.bookmarkAdded(addedBookmark))
        }
        sidebarMode = .bookmarks
    }

    func saveCurrentSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousItem = savedSearches.first(where: { $0.query == trimmed })
        repository.saveSearch(title: trimmed.isEmpty ? "Untitled Search" : trimmed, query: trimmed, selectedNoteID: selectedNoteID)
        savedSearches = repository.savedSearches
        guard let currentItem = savedSearches.first(where: { $0.query == trimmed }) else { return }
        if let previousItem {
            if previousItem != currentItem {
                registerAppUndoOperation(.savedSearchUpdated(old: previousItem, new: currentItem))
            }
        } else {
            registerAppUndoOperation(.savedSearchAdded(currentItem))
        }
    }

    func removeBookmark(_ bookmark: NoteBookmark) {
        repository.removeBookmark(id: bookmark.id)
        bookmarks = repository.bookmarks
        registerAppUndoOperation(.bookmarkRemoved(bookmark))
    }

    func removeSavedSearch(_ item: SavedSearchItem) {
        repository.deleteSavedSearch(id: item.id)
        savedSearches = repository.savedSearches
        registerAppUndoOperation(.savedSearchRemoved(item))
    }

    func toggleLayout() {
        let previous = preferences.layoutStyle
        let updated: LayoutStyle = previous == .horizontal ? .vertical : .horizontal
        preferences.layoutStyle = updated
        registerAppUndoOperation(.layoutChanged(from: previous, to: updated))
    }

    func setSortField(_ field: NoteSortField) {
        if preferences.sortField == field {
            preferences.sortReversed.toggle()
        } else {
            preferences.sortField = field
            preferences.sortReversed = defaultReverseSort(for: field)
        }
        sortOrder = Self.sortOrder(for: preferences)
    }

    func chooseNotesDirectory() {
        let panel = NSOpenPanel()
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = preferences.legacyStorage.notesDirectoryPath.isEmpty
            ? nil
            : URL(fileURLWithPath: preferences.legacyStorage.notesDirectoryPath)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyInternalPreferencesChange {
            preferences.legacyStorage.notesDirectoryPath = url.path
            preferences.legacyStorage.notesDirectoryBookmarkData = try? url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            preferences.legacyStorage.migrationState = .partiallyIntegrated
        }
        repository.savePreferences(preferences)
        refreshLegacyStorageStatus()
        if preferences.legacyStorage.backend == .legacyFileDirectory {
            importNotesFromConfiguredDirectory()
        } else if preferences.legacyStorage.backend == .legacySingleDatabase {
            loadNotesFromLegacySingleDatabase()
        }
    }

    func chooseExternalEditor() {
        let panel = NSOpenPanel()
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let newEditor = ExternalEditorPreference(
            id: UUID(),
            name: url.deletingPathExtension().lastPathComponent,
            bundlePath: url.path,
            isDefault: preferences.legacyStorage.externalEditors.isEmpty
        )

        if newEditor.isDefault {
            preferences.legacyStorage.externalEditors = [newEditor]
        } else {
            preferences.legacyStorage.externalEditors.append(newEditor)
        }
    }

    func makeExternalEditorDefault(_ editorID: UUID) {
        preferences.legacyStorage.externalEditors = preferences.legacyStorage.externalEditors.map { editor in
            var copy = editor
            copy.isDefault = copy.id == editorID
            return copy
        }
    }

    func removeExternalEditor(_ editorID: UUID) {
        preferences.legacyStorage.externalEditors.removeAll { $0.id == editorID }
        if !preferences.legacyStorage.externalEditors.contains(where: \.isDefault),
           let firstID = preferences.legacyStorage.externalEditors.first?.id {
            makeExternalEditorDefault(firstID)
        }
    }

    func setStorageBackend(_ backend: StorageBackendKind) {
        preferences.legacyStorage.backend = backend
        if backend != .legacySingleDatabase {
            cachedLegacyDatabasePassphraseData = nil
        }
        searchText = ""
        selectedTag = nil
        selectedNoteID = nil
        selectedNoteIDs.removeAll()
        preferences.legacyStorage.lastLoadSummary = "Not loaded"
        preferences.legacyStorage.lastLoadDetail = ""

        if backend == .legacyFileDirectory || backend == .legacySingleDatabase {
            notes = []
            filteredNotes = []
        } else {
            reloadFromRepository()
        }

        refreshLegacyStorageStatus()
        syncDirectoryMonitoring()

        if backend == .legacySingleDatabase, !preferences.legacyStorage.notesDirectoryPath.isEmpty {
            loadNotesFromLegacySingleDatabase()
        }
    }

    func reloadNotesFromActiveStorage() {
        switch preferences.legacyStorage.backend {
        case .rewriteJSON:
            reloadFromRepository()
            preferences.legacyStorage.lastLoadSummary = "Loaded rewrite store"
            preferences.legacyStorage.lastLoadDetail = "The rewrite JSON state is active."
        case .legacyFileDirectory:
            importNotesFromConfiguredDirectory(preserveUIState: true)
        case .legacySingleDatabase:
            loadNotesFromLegacySingleDatabase()
        }
    }

    func reloadNotesFromDiskIfNeeded() {
        guard preferences.legacyStorage.reloadsFromDiskOnActivate else { return }
        guard preferences.legacyStorage.backend == .legacyFileDirectory else { return }
        guard !preferences.legacyStorage.notesDirectoryPath.isEmpty else { return }
        importNotesFromConfiguredDirectory(preserveUIState: true)
    }

    func importNotesFromConfiguredDirectory(preserveUIState: Bool = false) {
        guard preferences.legacyStorage.backend == .legacyFileDirectory else { return }
        guard let directoryURL = resolvedNotesDirectoryURL() else {
            preferences.legacyStorage.lastLoadSummary = "Folder unavailable"
            preferences.legacyStorage.lastLoadDetail = "The configured notes folder could not be resolved."
            return
        }
        let adapter = LegacyDirectoryStorageAdapter()
        let imported = adapter.loadNotes(from: directoryURL.path)
        let changeSummary = directoryChangeSummary(for: imported)
        if preserveUIState, changeSummary.totalChanges == 0 {
            preferences.legacyStorage.lastLoadSummary = "No external changes"
            preferences.legacyStorage.lastLoadDetail = "Directory-backed notes in \(directoryURL.lastPathComponent) were checked and are already up to date."
            return
        }
        let reconciled = reconciledDirectoryNotes(imported)
        let preservedCount = zip(imported, reconciled).filter { $0.id != $1.id }.count
        let selectionID = preferredSelectedNoteID(afterReplacingWith: reconciled)
        repository.replaceAllNotes(reconciled, selectedNoteID: selectionID)
        preferences.legacyStorage.migrationState = .partiallyIntegrated
        preferences.legacyStorage.lastLoadSummary = reconciled.isEmpty
            ? "No notes found"
            : preserveUIState
                ? "Reloaded \(changeSummary.totalChanges) external change\(changeSummary.totalChanges == 1 ? "" : "s")"
                : "Loaded \(reconciled.count) notes"
        preferences.legacyStorage.lastLoadDetail = reconciled.isEmpty
            ? "The selected folder did not contain supported note files."
            : preserveUIState
                ? directoryReloadDetail(
                    folderName: directoryURL.lastPathComponent,
                    changeSummary: changeSummary,
                    preservedCount: preservedCount
                )
                : preservedCount == 0
                    ? "Directory-backed notes are active from \(directoryURL.lastPathComponent)."
                    : "Directory-backed notes are active from \(directoryURL.lastPathComponent), preserving \(preservedCount) existing note identities."
        if !preserveUIState {
            searchText = ""
            selectedTag = nil
        }
        selectedNoteID = selectionID
        selectedNoteIDs = selectionID.map { [$0] } ?? []
        reloadFromRepository()
        editorRefreshGeneration &+= 1
        browserRefreshGeneration &+= 1
    }

    func loadNotesFromLegacySingleDatabase() {
        guard preferences.legacyStorage.backend == .legacySingleDatabase else { return }
        guard let directoryURL = resolvedNotesDirectoryURL() else {
            preferences.legacyStorage.lastLoadSummary = "Folder unavailable"
            preferences.legacyStorage.lastLoadDetail = "The configured database folder could not be resolved."
            return
        }
        let adapter = LegacySingleDatabaseStorageAdapter()
        let result = loadLegacySingleDatabaseNotes(with: adapter, directoryURL: directoryURL)

        let imported: [Note]
        switch result {
        case .success(let notes, let source):
            imported = notes
            applyLegacyArchivePreferences(loadSource: source, baseDirectoryURL: directoryURL)
            preferences.legacyStorage.lastRecoverySource = recoverySource(for: source)
            preferences.legacyStorage.migrationState = notes.isEmpty ? .scaffolded : .partiallyIntegrated
            preferences.legacyStorage.lastLoadSummary = notes.isEmpty ? "Loaded 0 notes" : "Loaded \(notes.count) notes"
            preferences.legacyStorage.lastLoadDetail = legacySingleDatabaseLoadDetail(source: source, noteCount: notes.count)
        case .missingDatabase:
            imported = []
            preferences.legacyStorage.lastRecoverySource = nil
            preferences.legacyStorage.migrationState = .scaffolded
            preferences.legacyStorage.lastLoadSummary = "Database not found"
            preferences.legacyStorage.lastLoadDetail = "No 'Notes & Settings' file was found in the selected folder."
        case .unreadableArchive:
            imported = []
            preferences.legacyStorage.lastRecoverySource = nil
            preferences.legacyStorage.migrationState = .scaffolded
            preferences.legacyStorage.lastLoadSummary = "Unreadable database"
            preferences.legacyStorage.lastLoadDetail = "The archive could not be decoded as a supported Notational Velocity database."
        case .encryptedArchive:
            imported = []
            preferences.legacyStorage.lastRecoverySource = nil
            preferences.legacyStorage.migrationState = .scaffolded
            preferences.legacyStorage.lastLoadSummary = "Encrypted database"
            preferences.legacyStorage.lastLoadDetail = "A passphrase is required to open this legacy single-database archive."
        case .incorrectPassphrase:
            imported = []
            preferences.legacyStorage.lastRecoverySource = nil
            preferences.legacyStorage.migrationState = .scaffolded
            preferences.legacyStorage.lastLoadSummary = "Incorrect passphrase"
            preferences.legacyStorage.lastLoadDetail = "The provided passphrase could not decrypt the legacy single-database archive."
        case .decompressionFailed:
            imported = []
            preferences.legacyStorage.lastRecoverySource = nil
            preferences.legacyStorage.migrationState = .scaffolded
            preferences.legacyStorage.lastLoadSummary = "Decompression failed"
            preferences.legacyStorage.lastLoadDetail = "The legacy note payload could not be decompressed."
        case .noteDecodingFailed:
            imported = []
            preferences.legacyStorage.lastRecoverySource = nil
            preferences.legacyStorage.migrationState = .scaffolded
            preferences.legacyStorage.lastLoadSummary = "Note decoding failed"
            preferences.legacyStorage.lastLoadDetail = "The database opened, but the note archive format was not decoded successfully."
        }

        let selectionID = preferredSelectedNoteID(afterReplacingWith: imported)
        repository.replaceAllNotes(imported, selectedNoteID: selectionID)
        searchText = ""
        selectedTag = nil
        selectedNoteID = selectionID
        selectedNoteIDs = selectionID.map { [$0] } ?? []
        reloadFromRepository()
        editorRefreshGeneration &+= 1
        browserRefreshGeneration &+= 1
    }

    func recoverLegacySingleDatabaseFromBackup() {
        guard preferences.legacyStorage.backend == .legacySingleDatabase else { return }
        guard let directoryURL = resolvedNotesDirectoryURL() else {
            preferences.legacyStorage.lastLoadSummary = "Recovery unavailable"
            preferences.legacyStorage.lastLoadDetail = "Choose the database folder before attempting recovery."
            return
        }

        let adapter = LegacySingleDatabaseStorageAdapter()
        guard adapter.restoreBackup(at: directoryURL.path) else {
            preferences.legacyStorage.lastLoadSummary = "Recovery failed"
            preferences.legacyStorage.lastLoadDetail = "The backup snapshot could not be restored over Notes & Settings."
            return
        }

        preferences.legacyStorage.lastLoadSummary = "Recovered from backup"
        preferences.legacyStorage.lastLoadDetail = "The last backup snapshot was restored to Notes & Settings."
        loadNotesFromLegacySingleDatabase()
    }

    func recoverLegacySingleDatabaseFromJournal() {
        guard preferences.legacyStorage.backend == .legacySingleDatabase else { return }
        guard let directoryURL = resolvedNotesDirectoryURL() else {
            preferences.legacyStorage.lastLoadSummary = "Recovery unavailable"
            preferences.legacyStorage.lastLoadDetail = "Choose the database folder before attempting journal recovery."
            return
        }

        let adapter = LegacySingleDatabaseStorageAdapter()
        guard adapter.restoreJournal(at: directoryURL.path) else {
            preferences.legacyStorage.lastLoadSummary = "Journal recovery failed"
            preferences.legacyStorage.lastLoadDetail = "The pending journal could not be restored over Notes & Settings."
            return
        }

        preferences.legacyStorage.lastLoadSummary = "Recovered from journal"
        preferences.legacyStorage.lastLoadDetail = "The pending journal was restored to Notes & Settings."
        loadNotesFromLegacySingleDatabase()
    }

    func commitRecoveredLegacySingleDatabase() {
        guard preferences.legacyStorage.backend == .legacySingleDatabase,
              let directoryURL = resolvedNotesDirectoryURL(),
              let source = preferences.legacyStorage.lastRecoverySource else {
            return
        }

        let adapter = LegacySingleDatabaseStorageAdapter()
        guard adapter.commitRecoveredDatabase(at: directoryURL.path, source: source) else {
            preferences.legacyStorage.lastLoadSummary = "Commit failed"
            preferences.legacyStorage.lastLoadDetail = "The recovered archive could not be committed back to Notes & Settings."
            return
        }

        preferences.legacyStorage.lastLoadSummary = "Recovered archive committed"
        preferences.legacyStorage.lastLoadDetail = "The recovered \(source.rawValue) archive is now the primary Notes & Settings file."
        preferences.legacyStorage.lastRecoverySource = .database
        loadNotesFromLegacySingleDatabase()
    }

    func enableLegacyDatabaseEncryption() {
        guard ensureLegacySingleDatabaseReadyForWrite() else { return }

        guard let response = promptForPassphraseConfiguration(
            mode: .new,
            title: "Enable Note Encryption",
            message: "Choose a passphrase to protect your notes. If you forget it, recovery may be impossible."
        ) else {
            return
        }

        guard let masterSalt = LegacyEncryptionSupport.randomData(length: 256),
              let masterKey = LegacyEncryptionSupport.deriveKey(
                passphraseData: response.passphraseData,
                salt: masterSalt,
                keyLengthInBytes: response.keyLengthInBits / 8,
                iterations: response.hashIterationCount
              ),
              let verifierKey = LegacyEncryptionSupport.verifierKey(
                for: masterKey,
                keyLengthInBytes: response.keyLengthInBits / 8
              ) else {
            preferences.legacyStorage.lastLoadSummary = "Encryption setup failed"
            preferences.legacyStorage.lastLoadDetail = "The rewrite could not derive the legacy encryption keys."
            return
        }

        preferences.legacyStorage.encryptionEnabled = true
        preferences.legacyStorage.storesPasswordInKeychain = response.rememberInKeychain
        preferences.legacyStorage.hashIterationCount = response.hashIterationCount
        preferences.legacyStorage.keyLengthInBits = response.keyLengthInBits
        preferences.legacyStorage.masterSalt = masterSalt
        preferences.legacyStorage.verifierKey = verifierKey
        preferences.legacyStorage.dataSessionSalt = nil
        preferences.legacyStorage.keychainDatabaseIdentifier = preferences.legacyStorage.keychainDatabaseIdentifier ?? LegacyEncryptionSupport.generatedKeychainIdentifier()
        cachedLegacyDatabasePassphraseData = response.passphraseData

        if response.rememberInKeychain, let identifier = preferences.legacyStorage.keychainDatabaseIdentifier {
            _ = LegacyEncryptionSupport.storeKeychainPassphraseData(response.passphraseData, identifier: identifier)
        }

        syncAllNotesToActiveStorage()
        loadNotesFromLegacySingleDatabase()
        preferences.legacyStorage.lastLoadSummary = "Encryption enabled"
        preferences.legacyStorage.lastLoadDetail = "Legacy single-database writes are now encrypted with your configured passphrase."
    }

    func changeLegacyDatabasePassphrase() {
        guard preferences.legacyStorage.encryptionEnabled else {
            enableLegacyDatabaseEncryption()
            return
        }
        guard ensureLegacySingleDatabaseReadyForWrite() else { return }

        let currentPrefs = legacyNotationPrefsArchive()
        guard let currentPassphraseData = resolveLegacyDatabasePassphraseData(allowPrompt: true),
              LegacyEncryptionSupport.verify(passphraseData: currentPassphraseData, prefs: currentPrefs) != nil else {
            preferences.legacyStorage.lastLoadSummary = "Passphrase unavailable"
            preferences.legacyStorage.lastLoadDetail = "The current database passphrase could not be verified."
            return
        }

        guard let response = promptForPassphraseConfiguration(
            mode: .change,
            title: "Change Passphrase",
            message: "Enter a new passphrase for the encrypted note database."
        ) else {
            return
        }

        guard let masterSalt = LegacyEncryptionSupport.randomData(length: 256),
              let masterKey = LegacyEncryptionSupport.deriveKey(
                passphraseData: response.passphraseData,
                salt: masterSalt,
                keyLengthInBytes: response.keyLengthInBits / 8,
                iterations: response.hashIterationCount
              ),
              let verifierKey = LegacyEncryptionSupport.verifierKey(
                for: masterKey,
                keyLengthInBytes: response.keyLengthInBits / 8
              ) else {
            preferences.legacyStorage.lastLoadSummary = "Passphrase change failed"
            preferences.legacyStorage.lastLoadDetail = "The rewrite could not derive the replacement encryption keys."
            return
        }

        preferences.legacyStorage.hashIterationCount = response.hashIterationCount
        preferences.legacyStorage.keyLengthInBits = response.keyLengthInBits
        preferences.legacyStorage.masterSalt = masterSalt
        preferences.legacyStorage.verifierKey = verifierKey
        preferences.legacyStorage.dataSessionSalt = nil
        preferences.legacyStorage.storesPasswordInKeychain = response.rememberInKeychain
        preferences.legacyStorage.keychainDatabaseIdentifier = preferences.legacyStorage.keychainDatabaseIdentifier ?? LegacyEncryptionSupport.generatedKeychainIdentifier()
        cachedLegacyDatabasePassphraseData = response.passphraseData

        if let identifier = preferences.legacyStorage.keychainDatabaseIdentifier {
            if response.rememberInKeychain {
                _ = LegacyEncryptionSupport.storeKeychainPassphraseData(response.passphraseData, identifier: identifier)
            } else {
                LegacyEncryptionSupport.removeKeychainPassphraseData(identifier: identifier)
            }
        }

        syncAllNotesToActiveStorage()
        loadNotesFromLegacySingleDatabase()
        preferences.legacyStorage.lastLoadSummary = "Passphrase changed"
        preferences.legacyStorage.lastLoadDetail = "The encrypted database was rewritten with the new passphrase."
    }

    func disableLegacyDatabaseEncryption() {
        guard preferences.legacyStorage.encryptionEnabled else { return }
        guard ensureLegacySingleDatabaseReadyForWrite() else { return }
        let currentPrefs = legacyNotationPrefsArchive()
        guard let currentPassphraseData = resolveLegacyDatabasePassphraseData(allowPrompt: true),
              LegacyEncryptionSupport.verify(passphraseData: currentPassphraseData, prefs: currentPrefs) != nil else {
            preferences.legacyStorage.lastLoadSummary = "Passphrase unavailable"
            preferences.legacyStorage.lastLoadDetail = "The current database passphrase could not be verified."
            return
        }

        preferences.legacyStorage.encryptionEnabled = false
        preferences.legacyStorage.masterSalt = nil
        preferences.legacyStorage.dataSessionSalt = nil
        preferences.legacyStorage.verifierKey = nil
        cachedLegacyDatabasePassphraseData = nil

        if let identifier = preferences.legacyStorage.keychainDatabaseIdentifier {
            LegacyEncryptionSupport.removeKeychainPassphraseData(identifier: identifier)
        }
        preferences.legacyStorage.storesPasswordInKeychain = false

        syncAllNotesToActiveStorage()
        loadNotesFromLegacySingleDatabase()
        preferences.legacyStorage.lastLoadSummary = "Encryption disabled"
        preferences.legacyStorage.lastLoadDetail = "Legacy single-database writes are back to plain archive storage."
    }

    func setLegacyDatabaseStoresPasswordInKeychain(_ shouldStore: Bool) {
        preferences.legacyStorage.storesPasswordInKeychain = shouldStore

        guard let identifier = preferences.legacyStorage.keychainDatabaseIdentifier else { return }

        if shouldStore {
            guard let passphraseData = resolveLegacyDatabasePassphraseData(allowPrompt: true) else {
                preferences.legacyStorage.storesPasswordInKeychain = false
                preferences.legacyStorage.lastLoadSummary = "Keychain storage unavailable"
                preferences.legacyStorage.lastLoadDetail = "A verified passphrase is required before it can be stored in the Keychain."
                return
            }
            _ = LegacyEncryptionSupport.storeKeychainPassphraseData(passphraseData, identifier: identifier)
            preferences.legacyStorage.lastLoadSummary = "Passphrase stored"
            preferences.legacyStorage.lastLoadDetail = "The legacy database passphrase is now stored in the Keychain."
        } else {
            LegacyEncryptionSupport.removeKeychainPassphraseData(identifier: identifier)
            preferences.legacyStorage.lastLoadSummary = "Keychain storage disabled"
            preferences.legacyStorage.lastLoadDetail = "The stored passphrase was removed from the Keychain."
        }
    }

    func setNoteBodyFont(_ font: NSFont) {
        let regularizedFont = normalizedBodyFont(font)
        preferences.noteBodyFontName = regularizedFont.fontName
        preferences.noteBodyFontSize = regularizedFont.pointSize
    }

    func recordActivationHotKey() {
        guard let recorded = HotKeyRecorder.prompt(
            currentHotKey: preferences.activationHotKey,
            title: "Record Activation Hotkey",
            message: "Press the shortcut you want to use to bring Notation to the front."
        ) else {
            return
        }

        preferences.activationHotKey = recorded
        preferences.legacyStorage.lastLoadSummary = "Activation hotkey updated"
        preferences.legacyStorage.lastLoadDetail = "Global activation is now bound to \(recorded.displayString)."
    }

    func clearActivationHotKey() {
        preferences.activationHotKey.isEnabled = false
        preferences.legacyStorage.lastLoadSummary = "Activation hotkey cleared"
        preferences.legacyStorage.lastLoadDetail = "Global activation hotkey registration is disabled."
    }

    func showAboutPanel() {
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Notation",
            .applicationVersion: "SwiftUI Rewrite",
            .version: "Legacy-compatible port",
            .credits: bundledAcknowledgmentsAttributedString() ?? NSAttributedString(string: "Notational Velocity rewrite in progress.")
        ]
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openGettingStartedHelp() {
        openBundledHelpNote(resourceName: "How does this thing work?")
    }

    func openKeyboardShortcutsHelp() {
        openBundledHelpNote(resourceName: "Excruciatingly Useful Shortcuts")
    }

    func openContactInformationHelp() {
        openBundledHelpNote(resourceName: "Contact Information")
    }

    func openAcknowledgments() {
        if let acknowledgments = bundledAcknowledgmentsAttributedString() {
            openBundledNote(
                title: "Acknowledgments",
                body: acknowledgments,
                labels: ["help", "about"]
            )
        }
    }

    func openProjectWebsite() {
        guard let url = URL(string: "https://notational.net") else { return }
        NSWorkspace.shared.open(url)
    }

    func openDevelopmentWebsite() {
        guard let url = URL(string: "https://notational.net/development") else { return }
        NSWorkspace.shared.open(url)
    }

    func revealNotesDirectoryInFinder() {
        guard let directoryURL = resolvedNotesDirectoryURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
    }

    func migrateCurrentNotesToConfiguredDirectory() {
        guard let directoryURL = resolvedNotesDirectoryURL() else {
            preferences.legacyStorage.lastLoadSummary = "Folder unavailable"
            preferences.legacyStorage.lastLoadDetail = "Choose a notes folder before migrating notes."
            return
        }

        let adapter = LegacyDirectoryStorageAdapter()
        let sourceNotes = notes
        var migratedNotes: [Note] = []

        for note in sourceNotes {
            guard let migrated = try? adapter.writeNote(note, to: directoryURL.path) else {
                preferences.legacyStorage.lastLoadSummary = "Migration incomplete"
                preferences.legacyStorage.lastLoadDetail = "At least one note could not be written into the selected folder."
                return
            }
            migratedNotes.append(migrated)
        }

        preferences.legacyStorage.backend = .legacyFileDirectory
        preferences.legacyStorage.migrationState = .integrated
        preferences.legacyStorage.lastLoadSummary = migratedNotes.isEmpty ? "Migrated 0 notes" : "Migrated \(migratedNotes.count) notes"
        preferences.legacyStorage.lastLoadDetail = "The selected folder is now the active directory-backed store."
        let selectionID = preferredSelectedNoteID(afterReplacingWith: migratedNotes)
        repository.replaceAllNotes(migratedNotes, selectedNoteID: selectionID)
        selectedNoteID = selectionID
        selectedNoteIDs = selectionID.map { [$0] } ?? []
        refreshLegacyStorageStatus()
        reloadFromRepository()
    }

    func revealSelectedNoteInFinder() {
        guard let note = selectedNote else { return }

        if let fileURL = note.fileURL {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            return
        }

        let url = materializedURLForExternalAccess(for: note)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openSelectedNoteInExternalEditor() {
        guard let note = selectedNote else { return }
        let targetURL = materializedURLForExternalAccess(for: note)

        if let editor = preferences.legacyStorage.externalEditors.first(where: \.isDefault) {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([targetURL], withApplicationAt: URL(fileURLWithPath: editor.bundlePath), configuration: configuration) { _, _ in }
        } else {
            NSWorkspace.shared.open(targetURL)
        }
    }

    func importNotesFromFiles() {
        let panel = NSOpenPanel()
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = []

        guard panel.runModal() == .OK else { return }

        let adapter = LegacyDirectoryStorageAdapter()
        let importedNotes = adapter.loadNotes(from: panel.urls)
        guard !importedNotes.isEmpty else {
            preferences.legacyStorage.lastLoadSummary = "Import failed"
            preferences.legacyStorage.lastLoadDetail = "No supported note files were selected for import."
            return
        }

        let detachedNotes = importedNotes.map { importedNote in
            var copy = importedNote
            copy.fileURL = nil
            return copy
        }

        for note in detachedNotes {
            repository.upsert(note)
            upsertLocal(note)
        }

        let importedSelectionID = detachedNotes.first?.id
        if let importedSelectionID {
            select(noteID: importedSelectionID, cacheSearch: false)
        }
        syncAllNotesToActiveStorage()
        preferences.legacyStorage.lastLoadSummary = "Imported \(detachedNotes.count) notes"
        preferences.legacyStorage.lastLoadDetail = "Selected files were imported into the active storage backend."
    }

    func exportSelectedNotes() {
        let selectedNotes = notes.filter { selectedNoteIDs.contains($0.id) }
        guard !selectedNotes.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.prompt = "Export"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let directoryURL = panel.url else { return }

        let adapter = LegacyDirectoryStorageAdapter()
        for note in selectedNotes {
            _ = try? adapter.writeNote(note, to: directoryURL.path)
        }
    }

    func printSelectedNotes() {
        let selectedNotes = notes.filter { selectedNoteIDs.contains($0.id) }
        guard !selectedNotes.isEmpty else { return }

        let printableText = NSMutableAttributedString()
        for (index, note) in selectedNotes.enumerated() {
            let title = NSAttributedString(
                string: note.title + "\n",
                attributes: [.font: NSFont.boldSystemFont(ofSize: 15)]
            )
            printableText.append(title)
            printableText.append(note.body)
            if index < selectedNotes.count - 1 {
                printableText.append(NSAttributedString(string: "\n\n"))
            }
        }

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 720))
        textView.textStorage?.setAttributedString(printableText)
        textView.isEditable = false
        let operation = NSPrintOperation(view: textView)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }

    func reinterpretSelectedNoteEncoding(_ option: TextEncodingRepairOption) {
        guard preferences.legacyStorage.backend == .legacyFileDirectory else { return }
        guard let selectedNote else {
            preferences.legacyStorage.lastLoadSummary = "Encoding repair unavailable"
            preferences.legacyStorage.lastLoadDetail = "Select a plain-text file-backed note before reinterpreting its encoding."
            return
        }

        let adapter = LegacyDirectoryStorageAdapter()
        guard let repaired = adapter.reloadNote(selectedNote, withEncoding: option) else {
            preferences.legacyStorage.lastLoadSummary = "Encoding repair failed"
            preferences.legacyStorage.lastLoadDetail = "The selected note could not be reopened as \(option.displayName)."
            return
        }

        repository.upsert(repaired)
        upsertLocal(repaired)
        select(noteID: repaired.id, cacheSearch: false)
        let synced = syncNoteToActiveStorage(repaired)
        if synced.fileURL != repaired.fileURL || synced.modifiedAt != repaired.modifiedAt || synced.syncMetadata != repaired.syncMetadata {
            repository.upsert(synced)
            upsertLocal(synced)
            select(noteID: synced.id, cacheSearch: false)
        }
        preferences.legacyStorage.lastLoadSummary = "Reinterpreted text encoding"
        preferences.legacyStorage.lastLoadDetail = "The selected plain-text note was reopened and rewritten as \(option.displayName)."
    }

    func promptToRepairSelectedNoteEncoding() {
        guard canRepairSelectedNoteEncoding, let selectedNote else {
            preferences.legacyStorage.lastLoadSummary = "Encoding repair unavailable"
            preferences.legacyStorage.lastLoadDetail = "Select a plain-text directory-backed note before repairing its text encoding."
            return
        }

        let alert = NSAlert()
        alert.messageText = "Repair Text Encoding"
        alert.informativeText = "Reopen and rewrite \"\(selectedNote.title)\" using the selected plain-text encoding."
        alert.addButton(withTitle: "Repair")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 54))
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 12, width: 320, height: 28), pullsDown: false)
        TextEncodingRepairOption.allCases.forEach { option in
            popup.addItem(withTitle: option.displayName)
            popup.lastItem?.representedObject = option.rawValue
        }
        if let currentRawEncoding = selectedNote.syncMetadata["textEncoding"].flatMap(UInt.init),
           let currentEncoding = TextEncodingRepairOption.allCases.first(where: { $0.stringEncoding.rawValue == currentRawEncoding }),
           let selectedIndex = TextEncodingRepairOption.allCases.firstIndex(of: currentEncoding) {
            popup.selectItem(at: selectedIndex)
        }
        container.addSubview(popup)
        alert.accessoryView = container

        guard alert.runModal() == .alertFirstButtonReturn,
              let rawValue = popup.selectedItem?.representedObject as? String,
              let option = TextEncodingRepairOption(rawValue: rawValue) else {
            return
        }

        reinterpretSelectedNoteEncoding(option)
    }

    func handleIncomingURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              ["nv", "notation", "notationalvelocity"].contains(scheme) else {
            return
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        let command = url.host?.lowercased() ?? pathComponents.first?.lowercased()

        switch command {
        case "find":
            let rawTarget: String
            if url.host?.lowercased() == "find" {
                rawTarget = pathComponents.joined(separator: "/")
            } else {
                rawTarget = pathComponents.dropFirst().joined(separator: "/")
            }
            let queryTarget = components?.queryItems?.first(where: { ["q", "find", "title", "id"].contains($0.name.lowercased()) })?.value
            let target = (queryTarget ?? rawTarget).removingPercentEncoding ?? (queryTarget ?? rawTarget)
            handleFindURLTarget(target)
        default:
            preferences.legacyStorage.lastLoadSummary = "Unsupported URL"
            preferences.legacyStorage.lastLoadDetail = "The rewrite received \(url.absoluteString), but only nv://find/... URLs are handled right now."
        }
    }

    private func saveUIState() {
        repository.saveUIState(
            searchText: searchText,
            selectedNoteID: selectedNoteID,
            selectedTag: selectedTag,
            sidebarMode: sidebarMode
        )
    }

    private func upsertLocal(_ note: Note) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = note
        } else {
            notes.append(note)
        }
        notes.sort(by: noteSortComparator)

        bookmarks = repository.bookmarks
        savedSearches = repository.savedSearches
        syncStates = repository.syncStates
        rebuildDerivedCollections()
    }

    private func registerUndoRevision(for note: Note, coalescing: Bool) {
        var history = noteHistories[note.id] ?? NoteUndoHistory()
        let currentRevision = NoteRevision(
            title: note.title,
            body: NSAttributedString(attributedString: note.body),
            labels: note.labels,
            selectedRange: note.selectedRange
        )
        let now = Date()

        if coalescing,
           let lastRegisteredAt = history.lastRegisteredAt,
           now.timeIntervalSince(lastRegisteredAt) < 0.8,
           !history.undoStack.isEmpty {
            history.lastRegisteredAt = now
            noteHistories[note.id] = history
            return
        }

        if let last = history.undoStack.last,
           last.title == currentRevision.title,
           last.labels == currentRevision.labels,
           last.selectedRange == currentRevision.selectedRange,
           last.body.isEqual(to: currentRevision.body) {
            history.lastRegisteredAt = now
            noteHistories[note.id] = history
            return
        }

        history.undoStack.append(currentRevision)
        if history.undoStack.count > 100 {
            history.undoStack.removeFirst(history.undoStack.count - 100)
        }
        history.redoStack.removeAll()
        history.lastRegisteredAt = now
        noteHistories[note.id] = history
    }

    private func registerAppUndoOperation(_ operation: AppUndoOperation) {
        appUndoStack.append(operation)
        if appUndoStack.count > 100 {
            appUndoStack.removeFirst(appUndoStack.count - 100)
        }
        appRedoStack.removeAll()
    }

    private func applyUndoOperation(_ operation: AppUndoOperation) {
        switch operation {
        case .created(let note):
            if preferences.legacyStorage.backend == .legacyFileDirectory {
                LegacyDirectoryStorageAdapter().removeNote(note)
            }
            repository.remove(noteIDs: [note.id])
            reloadFromRepository()
            selectedNoteID = filteredNotes.first?.id
            selectedNoteIDs = selectedNoteID.map { [$0] } ?? []
            appRedoStack.append(.created(note))
        case .deleted(let deletedNotes, let previouslySelectedNoteID):
            for note in deletedNotes {
                repository.upsert(note)
                upsertLocal(note)
                if preferences.legacyStorage.backend == .legacyFileDirectory,
                   let directoryURL = resolvedNotesDirectoryURL() {
                    _ = try? LegacyDirectoryStorageAdapter().writeNote(note, to: directoryURL.path)
                }
            }
            reloadFromRepository()
            if let previouslySelectedNoteID,
               notes.contains(where: { $0.id == previouslySelectedNoteID }) {
                selectedNoteID = previouslySelectedNoteID
            } else {
                selectedNoteID = deletedNotes.first?.id
            }
            selectedNoteIDs = selectedNoteID.map { [$0] } ?? []
            syncAllNotesToActiveStorage()
            appRedoStack.append(.deleted(notes: deletedNotes, previouslySelectedNoteID: previouslySelectedNoteID))
        case .bookmarkAdded(let bookmark):
            repository.removeBookmark(id: bookmark.id)
            bookmarks = repository.bookmarks
            appRedoStack.append(.bookmarkAdded(bookmark))
        case .bookmarkRemoved(let bookmark):
            repository.upsertBookmark(bookmark)
            bookmarks = repository.bookmarks
            sidebarMode = .bookmarks
            appRedoStack.append(.bookmarkRemoved(bookmark))
        case .savedSearchAdded(let item):
            repository.deleteSavedSearch(id: item.id)
            savedSearches = repository.savedSearches
            appRedoStack.append(.savedSearchAdded(item))
        case .savedSearchUpdated(let old, let new):
            repository.upsertSavedSearch(old)
            savedSearches = repository.savedSearches
            sidebarMode = .savedSearches
            appRedoStack.append(.savedSearchUpdated(old: old, new: new))
        case .savedSearchRemoved(let item):
            repository.upsertSavedSearch(item)
            savedSearches = repository.savedSearches
            sidebarMode = .savedSearches
            appRedoStack.append(.savedSearchRemoved(item))
        case .layoutChanged(let from, let to):
            preferences.layoutStyle = from
            appRedoStack.append(.layoutChanged(from: from, to: to))
        }
        editorRefreshGeneration &+= 1
        browserRefreshGeneration &+= 1
    }

    private func applyRedoOperation(_ operation: AppUndoOperation) {
        switch operation {
        case .created(let note):
            repository.upsert(note)
            upsertLocal(note)
            if preferences.legacyStorage.backend == .legacyFileDirectory,
               let directoryURL = resolvedNotesDirectoryURL() {
                _ = try? LegacyDirectoryStorageAdapter().writeNote(note, to: directoryURL.path)
            }
            select(noteID: note.id, cacheSearch: false)
            syncAllNotesToActiveStorage()
            appUndoStack.append(.created(note))
        case .deleted(let deletedNotes, let previouslySelectedNoteID):
            let noteIDs = Set(deletedNotes.map(\.id))
            if preferences.legacyStorage.backend == .legacyFileDirectory {
                let adapter = LegacyDirectoryStorageAdapter()
                deletedNotes.forEach { adapter.removeNote($0) }
            }
            repository.remove(noteIDs: noteIDs)
            reloadFromRepository()
            if let previouslySelectedNoteID, !noteIDs.contains(previouslySelectedNoteID) {
                selectedNoteID = previouslySelectedNoteID
            } else {
                selectedNoteID = filteredNotes.first?.id
            }
            selectedNoteIDs = selectedNoteID.map { [$0] } ?? []
            syncAllNotesToActiveStorage()
            appUndoStack.append(.deleted(notes: deletedNotes, previouslySelectedNoteID: previouslySelectedNoteID))
        case .bookmarkAdded(let bookmark):
            repository.upsertBookmark(bookmark)
            bookmarks = repository.bookmarks
            sidebarMode = .bookmarks
            appUndoStack.append(.bookmarkAdded(bookmark))
        case .bookmarkRemoved(let bookmark):
            repository.removeBookmark(id: bookmark.id)
            bookmarks = repository.bookmarks
            appUndoStack.append(.bookmarkRemoved(bookmark))
        case .savedSearchAdded(let item):
            repository.upsertSavedSearch(item)
            savedSearches = repository.savedSearches
            sidebarMode = .savedSearches
            appUndoStack.append(.savedSearchAdded(item))
        case .savedSearchUpdated(let old, let new):
            repository.upsertSavedSearch(new)
            savedSearches = repository.savedSearches
            sidebarMode = .savedSearches
            appUndoStack.append(.savedSearchUpdated(old: old, new: new))
        case .savedSearchRemoved(let item):
            repository.deleteSavedSearch(id: item.id)
            savedSearches = repository.savedSearches
            appUndoStack.append(.savedSearchRemoved(item))
        case .layoutChanged(let from, let to):
            preferences.layoutStyle = to
            appUndoStack.append(.layoutChanged(from: from, to: to))
        }
        editorRefreshGeneration &+= 1
        browserRefreshGeneration &+= 1
    }

    private func defaultReverseSort(for field: NoteSortField) -> Bool {
        switch field {
        case .title, .labels:
            return false
        case .modified, .created:
            return true
        }
    }

    private func noteSortComparator(lhs: Note, rhs: Note) -> Bool {
        if !sortOrder.isEmpty {
            for comparator in sortOrder {
                let result = comparator.compare(lhs, rhs)
                if result == .orderedAscending {
                    return true
                }
                if result == .orderedDescending {
                    return false
                }
            }
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private static func sortOrder(for preferences: NVPreferences) -> [KeyPathComparator<Note>] {
        let order: SortOrder = preferences.sortReversed ? .reverse : .forward
        switch preferences.sortField {
        case .title:
            return [KeyPathComparator(\Note.title, order: order)]
        case .labels:
            return [KeyPathComparator(\Note.labelsText, order: order)]
        case .modified:
            return [KeyPathComparator(\Note.modifiedAt, order: order)]
        case .created:
            return [KeyPathComparator(\Note.createdAt, order: order)]
        }
    }

    private func syncPreferencesFromSortOrder() {
        guard let first = sortOrder.first else { return }
        switch first.keyPath {
        case \Note.title:
            preferences.sortField = .title
        case \Note.labelsText:
            preferences.sortField = .labels
        case \Note.modifiedAt:
            preferences.sortField = .modified
        case \Note.createdAt:
            preferences.sortField = .created
        default:
            break
        }
        preferences.sortReversed = first.order == .reverse
    }

    private func refreshLegacyStorageStatus() {
        let adapter = makeLegacyStorageAdapter(for: preferences.legacyStorage.backend)
        preferences.legacyStorage.supportsLegacyRead = adapter.canReadLegacyStore()
        preferences.legacyStorage.supportsLegacyWrite = adapter.canWriteLegacyStore()
        preferences.legacyStorage.supportsDirectorySync = adapter.supportsDirectorySync()
        preferences.legacyStorage.supportsJournaling = adapter.supportsJournaling()
        preferences.legacyStorage.supportedFormats = adapter.supportedFormats()
        preferences.legacyStorage.supportsExternalFileImport = preferences.legacyStorage.backend == .legacyFileDirectory
        if preferences.legacyStorage.backend == .rewriteJSON {
            preferences.legacyStorage.databaseFileName = "state.json"
        } else if preferences.legacyStorage.backend == .legacySingleDatabase {
            preferences.legacyStorage.databaseFileName = "Notes & Settings"
        } else {
            preferences.legacyStorage.databaseFileName = "Directory-backed notes"
        }
    }

    private func syncNoteToActiveStorage(_ note: Note) -> Note {
        guard preferences.legacyStorage.backend == .legacyFileDirectory,
              let directoryURL = resolvedNotesDirectoryURL() else {
            return note
        }

        let adapter = LegacyDirectoryStorageAdapter()
        suppressDirectoryRefresh(for: 0.5)
        if let fileURL = note.fileURL,
           adapter.hasExternalConflict(for: note, at: fileURL) {
            preferences.legacyStorage.lastLoadSummary = "External change overwritten"
            preferences.legacyStorage.lastLoadDetail = "The file changed on disk while this note had in-memory edits. Following original NV behavior, the rewrite kept the in-app version."
        }
        return (try? adapter.writeNote(note, to: directoryURL.path)) ?? note
    }

    private func directoryChangeSummary(for importedNotes: [Note]) -> (added: Int, removed: Int, modified: Int, totalChanges: Int) {
        let currentDirectoryNotes = notes.filter { $0.fileURL != nil }
        let currentPairs: [(String, Note)] = currentDirectoryNotes.compactMap { note in
            guard let path = note.fileURL?.standardizedFileURL.path else { return nil }
            return (path, note)
        }
        let importedPairs: [(String, Note)] = importedNotes.compactMap { note in
            guard let path = note.fileURL?.standardizedFileURL.path else { return nil }
            return (path, note)
        }
        let currentByPath = Dictionary(uniqueKeysWithValues: currentPairs)
        let importedByPath = Dictionary(uniqueKeysWithValues: importedPairs)

        let currentPaths = Set(currentByPath.keys)
        let importedPaths = Set(importedByPath.keys)

        let added = importedPaths.subtracting(currentPaths).count
        let removed = currentPaths.subtracting(importedPaths).count
        let modified = importedPaths.intersection(currentPaths).reduce(into: 0) { count, path in
            guard let current = currentByPath[path], let imported = importedByPath[path] else { return }
            if current.modifiedAt != imported.modifiedAt ||
                current.plainBody != imported.plainBody ||
                current.title != imported.title ||
                current.syncMetadata["fileSize"] != imported.syncMetadata["fileSize"] ||
                current.syncMetadata["fileModificationTimeInterval"] != imported.syncMetadata["fileModificationTimeInterval"] {
                count += 1
            }
        }

        return (added: added, removed: removed, modified: modified, totalChanges: added + removed + modified)
    }

    private func directoryReloadDetail(folderName: String, changeSummary: (added: Int, removed: Int, modified: Int, totalChanges: Int), preservedCount: Int) -> String {
        var parts: [String] = []
        if changeSummary.added > 0 {
            parts.append("\(changeSummary.added) added")
        }
        if changeSummary.modified > 0 {
            parts.append("\(changeSummary.modified) changed")
        }
        if changeSummary.removed > 0 {
            parts.append("\(changeSummary.removed) removed")
        }
        if parts.isEmpty {
            parts.append("no visible changes")
        }

        let preservedDetail = preservedCount == 0 ? "" : " Preserved \(preservedCount) existing note identities."
        return "Directory-backed notes were reloaded from \(folderName): \(parts.joined(separator: ", ")).\(preservedDetail)"
    }

    private func syncAllNotesToActiveStorage() {
        switch preferences.legacyStorage.backend {
        case .rewriteJSON:
            return
        case .legacyFileDirectory:
            guard let selectedNote else { return }
            let synced = syncNoteToActiveStorage(selectedNote)
            if synced.fileURL != selectedNote.fileURL || synced.modifiedAt != selectedNote.modifiedAt || synced.syncMetadata != selectedNote.syncMetadata {
                repository.upsert(synced)
                upsertLocal(synced)
            }
        case .legacySingleDatabase:
            guard let directoryURL = resolvedNotesDirectoryURL() else {
                preferences.legacyStorage.lastLoadSummary = "Database folder unavailable"
                preferences.legacyStorage.lastLoadDetail = "Choose a folder for the legacy single-database backend."
                return
            }
            let adapter = LegacySingleDatabaseStorageAdapter()
            let writeResult = adapter.writeNotes(
                notes,
                to: directoryURL.path,
                prefs: legacyNotationPrefsArchive(),
                passphraseData: preferences.legacyStorage.encryptionEnabled ? resolveLegacyDatabasePassphraseData(allowPrompt: true) : nil
            )
            guard case let .success(persistedNotes, backupCreated, journalCreated) = writeResult else {
                if case let .failure(message) = writeResult {
                    preferences.legacyStorage.lastLoadSummary = "Database write failed"
                    preferences.legacyStorage.lastLoadDetail = message
                }
                return
            }
            let selectionID = preferredSelectedNoteID(afterReplacingWith: persistedNotes)
            repository.replaceAllNotes(persistedNotes, selectedNoteID: selectionID)
            notes = persistedNotes
            selectedNoteID = selectionID
            selectedNoteIDs = selectionID.map { [$0] } ?? []
            preferences.legacyStorage.lastLoadSummary = persistedNotes.isEmpty ? "Saved 0 notes" : "Saved \(persistedNotes.count) notes"
            preferences.legacyStorage.lastLoadDetail =
                journalCreated
                ? (backupCreated
                    ? "Legacy single-database write-back completed after appending WAL journal records and creating a backup snapshot."
                    : "Legacy single-database write-back completed after appending WAL journal records.")
                : (backupCreated
                    ? "Legacy single-database write-back completed after creating a backup snapshot."
                    : "Legacy single-database write-back completed.")
            rebuildDerivedCollections()
        }
    }

    private func syncGlobalHotKeyRegistration() {
        guard preferences.activationHotKey.isEnabled else {
            globalHotKeyManager.unregister()
            return
        }

        let didRegister = globalHotKeyManager.register(hotKey: preferences.activationHotKey) { [weak self] in
            self?.toggleAppActivation()
        }

        if !didRegister {
            preferences.legacyStorage.lastLoadSummary = "Hotkey registration failed"
            preferences.legacyStorage.lastLoadDetail = "The requested global activation shortcut could not be registered."
        }
    }

    private func toggleAppActivation() {
        if NSApp.isActive, let keyWindow = NSApp.keyWindow, keyWindow.isMainWindow {
            NSApp.hide(nil)
            return
        }

        if NSApp.windows.allSatisfy({ !$0.isVisible || $0.isMiniaturized }) {
            NVWindowActivationBridge.shared.openMainWindow?()
        }

        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        let candidateWindow =
            NSApp.windows.first(where: { $0.isMainWindow }) ??
            NSApp.windows.first(where: { $0.canBecomeMain && !$0.isMiniaturized }) ??
            NSApp.windows.first(where: { !$0.isMiniaturized })

        candidateWindow?.orderFrontRegardless()
        candidateWindow?.makeKeyAndOrderFront(nil)

        DispatchQueue.main.async {
            NVSearchField.focusActiveField()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NVSearchField.focusActiveField()
        }
    }

    private func materializedURLForExternalAccess(for note: Note) -> URL {
        if let fileURL = note.fileURL {
            return fileURL
        }

        let tempDirectory = JSONNoteRepository.defaultRepositoryBaseURL()
            .appendingPathComponent("External Editing", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let adapter = LegacyDirectoryStorageAdapter()
        return (try? adapter.writeNote(note, to: tempDirectory.path).fileURL) ?? tempDirectory.appendingPathComponent("Untitled Note.txt")
    }

    private func normalizedBodyFont(_ font: NSFont) -> NSFont {
        let manager = NSFontManager.shared
        var normalized = manager.convert(font, toNotHaveTrait: .boldFontMask)
        normalized = manager.convert(normalized, toNotHaveTrait: .italicFontMask)
        return normalized
    }

    private func openBundledHelpNote(resourceName: String) {
        guard let url = bundledResourceURL(named: resourceName, extension: "nvhelp"),
              let attributedBody = try? NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
              ) else {
            preferences.legacyStorage.lastLoadSummary = "Help unavailable"
            preferences.legacyStorage.lastLoadDetail = "The bundled help document '\(resourceName)' could not be loaded."
            return
        }

        openBundledNote(title: resourceName, body: attributedBody, labels: ["help"])
    }

    private func bundledAcknowledgmentsAttributedString() -> NSAttributedString? {
        guard let url = bundledResourceURL(named: "Acknowledgments", extension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2
        let bodyFont = NSFont(
            name: preferences.noteBodyFontName,
            size: preferences.noteBodyFontSize
        ) ?? NSFont.monospacedSystemFont(ofSize: preferences.noteBodyFontSize, weight: .regular)
        return NSAttributedString(
            string: text,
            attributes: [
                .font: bodyFont,
                .foregroundColor: preferences.foregroundColor.nsColor,
                .paragraphStyle: paragraphStyle
            ]
        )
    }

    private func openBundledNote(title: String, body: NSAttributedString, labels: [String]) {
        if let existing = notes.first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
            sidebarMode = .notes
            searchText = title
            selectedTag = nil
            rebuildDerivedCollections()
            select(noteID: existing.id, cacheSearch: false)
            return
        }

        var note = Note(title: title, body: body, labels: labels)
        note.syncMetadata["bundledDocument"] = "true"
        repository.upsert(note)
        upsertLocal(note)
        sidebarMode = .notes
        searchText = title
        selectedTag = nil
        rebuildDerivedCollections()
        select(noteID: note.id, cacheSearch: false)
        syncAllNotesToActiveStorage()
    }

    private func bundledResourceURL(named name: String, extension ext: String) -> URL? {
        if let bundleURL = Bundle.main.url(forResource: name, withExtension: ext) {
            return bundleURL
        }

        let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidateURLs = [
            cwdURL.appendingPathComponent("\(name).\(ext)"),
            cwdURL.appendingPathComponent("en.lproj/\(name).\(ext)")
        ]

        return candidateURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private func reconciledDirectoryNotes(_ imported: [Note]) -> [Note] {
        let existingByPath = Dictionary(
            uniqueKeysWithValues: notes.compactMap { note in
                note.fileURL.map { (normalizedPath($0), note) }
            }
        )

        return imported.map { importedNote in
            guard let fileURL = importedNote.fileURL else { return importedNote }
            guard let existing = existingByPath[normalizedPath(fileURL)] else { return importedNote }

            var reconciled = importedNote
            reconciled = Note(
                id: existing.id,
                title: importedNote.title,
                body: importedNote.body,
                labels: existing.labels,
                createdAt: importedNote.createdAt,
                modifiedAt: importedNote.modifiedAt,
                selectedRange: existing.selectedRange,
                fileURL: importedNote.fileURL,
                syncMetadata: existing.syncMetadata.merging(importedNote.syncMetadata) { _, imported in imported }
            )
            return reconciled
        }
    }

    private func preferredSelectedNoteID(afterReplacingWith replacementNotes: [Note]) -> UUID? {
        let validIDs = Set(replacementNotes.map(\.id))
        if let selectedNoteID, validIDs.contains(selectedNoteID) {
            return selectedNoteID
        }

        if let currentSelectedPath = selectedNote?.fileURL.map(normalizedPath) {
            return replacementNotes.first(where: { $0.fileURL.map(normalizedPath) == currentSelectedPath })?.id
        }

        return replacementNotes.first?.id
    }

    private func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func handleFindURLTarget(_ target: String) {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearSearch()
            return
        }

        sidebarMode = .notes
        selectedTag = nil

        if let noteID = UUID(uuidString: trimmed),
           let matchedNote = notes.first(where: { $0.id == noteID }) {
            searchText = ""
            rebuildDerivedCollections()
            select(noteID: matchedNote.id, cacheSearch: false)
            return
        }

        searchText = trimmed
        rebuildDerivedCollections()

        if let exactTitleMatch = filteredNotes.first(where: { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            select(noteID: exactTitleMatch.id, cacheSearch: false)
            return
        }

        select(noteID: preferredSelectedNote?.id, cacheSearch: false)
    }

    private func loadLegacySingleDatabaseNotes(with adapter: LegacySingleDatabaseStorageAdapter, directoryURL: URL) -> LegacySingleDatabaseLoadResult {
        applyLegacyArchivePreferences(loadSource: .database, baseDirectoryURL: directoryURL)

        let passphraseData = resolveLegacyDatabasePassphraseData(allowPrompt: false)
        var result = adapter.loadNotes(
            from: directoryURL.path,
            preferredFontName: preferences.noteBodyFontName,
            preferredFontSize: preferences.noteBodyFontSize,
            passphraseData: passphraseData
        )

        if case .encryptedArchive = result,
           let promptedPassphrase = promptForUnlockPassphrase() {
            cachedLegacyDatabasePassphraseData = promptedPassphrase.passphraseData
            if promptedPassphrase.rememberInKeychain,
               let identifier = preferences.legacyStorage.keychainDatabaseIdentifier {
                _ = LegacyEncryptionSupport.storeKeychainPassphraseData(promptedPassphrase.passphraseData, identifier: identifier)
                preferences.legacyStorage.storesPasswordInKeychain = true
            }
            result = adapter.loadNotes(
                from: directoryURL.path,
                preferredFontName: preferences.noteBodyFontName,
                preferredFontSize: preferences.noteBodyFontSize,
                passphraseData: promptedPassphrase.passphraseData
            )
        }

        return result
    }

    private func ensureLegacySingleDatabaseReadyForWrite() -> Bool {
        if preferences.legacyStorage.backend != .legacySingleDatabase {
            setStorageBackend(.legacySingleDatabase)
        }

        if preferences.legacyStorage.notesDirectoryPath.isEmpty {
            chooseNotesDirectory()
        }

        guard !preferences.legacyStorage.notesDirectoryPath.isEmpty,
              resolvedNotesDirectoryURL() != nil else {
            preferences.legacyStorage.lastLoadSummary = "Database folder required"
            preferences.legacyStorage.lastLoadDetail = "Choose a legacy single-database folder before changing encryption settings."
            return false
        }

        return true
    }

    private func resolveLegacyDatabasePassphraseData(allowPrompt: Bool) -> Data? {
        if let cachedLegacyDatabasePassphraseData {
            return cachedLegacyDatabasePassphraseData
        }

        if let identifier = preferences.legacyStorage.keychainDatabaseIdentifier,
           let keychainData = LegacyEncryptionSupport.keychainPassphraseData(identifier: identifier) {
            cachedLegacyDatabasePassphraseData = keychainData
            return keychainData
        }

        guard allowPrompt,
              let prompted = promptForUnlockPassphrase() else {
            return nil
        }

        cachedLegacyDatabasePassphraseData = prompted.passphraseData
        if prompted.rememberInKeychain,
           let identifier = preferences.legacyStorage.keychainDatabaseIdentifier {
            _ = LegacyEncryptionSupport.storeKeychainPassphraseData(prompted.passphraseData, identifier: identifier)
            preferences.legacyStorage.storesPasswordInKeychain = true
        }
        return prompted.passphraseData
    }

    private func legacyNotationPrefsArchive() -> LegacyNotationPrefsArchive {
        LegacyNotationPrefsArchive(
            doesEncryption: preferences.legacyStorage.encryptionEnabled,
            storesPasswordInKeychain: preferences.legacyStorage.storesPasswordInKeychain,
            secureTextEntry: preferences.secureTextEntry,
            hashIterationCount: preferences.legacyStorage.hashIterationCount,
            keyLengthInBits: preferences.legacyStorage.keyLengthInBits,
            keychainDatabaseIdentifier: preferences.legacyStorage.keychainDatabaseIdentifier,
            masterSalt: preferences.legacyStorage.masterSalt,
            dataSessionSalt: preferences.legacyStorage.dataSessionSalt,
            verifierKey: preferences.legacyStorage.verifierKey,
            epochIteration: 4
        )
    }

    private func applyLegacyArchivePreferences(_ archivePrefs: LegacyNotationPrefsArchive) {
        preferences.legacyStorage.encryptionEnabled = archivePrefs.doesEncryption
        preferences.legacyStorage.storesPasswordInKeychain = archivePrefs.storesPasswordInKeychain
        preferences.legacyStorage.hashIterationCount = archivePrefs.hashIterationCount
        preferences.legacyStorage.keyLengthInBits = archivePrefs.keyLengthInBits
        preferences.legacyStorage.keychainDatabaseIdentifier = archivePrefs.keychainDatabaseIdentifier
        preferences.legacyStorage.masterSalt = archivePrefs.masterSalt
        preferences.legacyStorage.dataSessionSalt = archivePrefs.dataSessionSalt
        preferences.legacyStorage.verifierKey = archivePrefs.verifierKey
        preferences.secureTextEntry = archivePrefs.secureTextEntry
    }

    private func applyLegacyArchivePreferences(loadSource: LegacySingleDatabaseLoadSource, baseDirectoryURL: URL) {
        let filename: String
        switch loadSource {
        case .database:
            filename = LegacySingleDatabaseStorageAdapter.databaseFileName
        case .journal:
            filename = LegacySingleDatabaseStorageAdapter.journalFileName
        case .backup:
            filename = LegacySingleDatabaseStorageAdapter.backupFileName
        }

        if let frozenNotation = LegacySingleDatabaseArchiveLoader.loadFrozenNotation(from: baseDirectoryURL.appendingPathComponent(filename)),
           let prefs = frozenNotation.prefs {
            applyLegacyArchivePreferences(prefs)
        }
    }

    private func promptForUnlockPassphrase() -> (passphraseData: Data, rememberInKeychain: Bool)? {
        let alert = NSAlert()
        alert.messageText = "Unlock Encrypted Notes"
        alert.informativeText = "Enter the passphrase required to access this encrypted legacy note database."
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")

        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 64))

        let passphraseField = NSSecureTextField(frame: NSRect(x: 0, y: 32, width: 340, height: 24))
        passphraseField.placeholderString = "Passphrase"
        let rememberButton = NSButton(checkboxWithTitle: "Remember passphrase in Keychain", target: nil, action: nil)
        rememberButton.frame = NSRect(x: 0, y: 0, width: 340, height: 18)

        accessoryView.addSubview(passphraseField)
        accessoryView.addSubview(rememberButton)
        alert.accessoryView = accessoryView

        guard alert.runModal() == .alertFirstButtonReturn,
              !passphraseField.stringValue.isEmpty,
              let passphraseData = passphraseField.stringValue.data(using: .utf8) else {
            return nil
        }

        return (passphraseData, rememberButton.state == .on)
    }

    private func parsedSearchTerms(from query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count > 1 {
            let phrase = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            return phrase.isEmpty ? [] : [phrase]
        }

        let pattern = #""([^"]+)"|(\S+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        }

        let nsQuery = trimmed as NSString
        let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: nsQuery.length))
        return matches.compactMap { match in
            if match.range(at: 1).location != NSNotFound {
                return nsQuery.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if match.range(at: 2).location != NSNotFound {
                return nsQuery.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }
        .filter { !$0.isEmpty }
    }

    private func legacySingleDatabaseLoadDetail(source: LegacySingleDatabaseLoadSource, noteCount: Int) -> String {
        guard noteCount > 0 else {
            return "The legacy archive opened, but no notes were decoded."
        }

        switch source {
        case .database:
            return "Legacy single-database notes are loaded with rewrite write-back enabled for unencrypted archives."
        case .journal:
            return "The main archive could not be used, so notes were recovered from the pending journal snapshot. Commit the recovered journal if you want Notes & Settings rewritten from it."
        case .backup:
            return "The main archive and journal could not be used, so notes were recovered from the backup snapshot. Commit the recovered backup if you want Notes & Settings rewritten from it."
        }
    }

    private enum PassphrasePromptMode {
        case new
        case change
    }

    private func promptForPassphraseConfiguration(
        mode: PassphrasePromptMode,
        title: String,
        message: String
    ) -> LegacyPassphraseDialogResult? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        let includesCurrentPassword = mode == .change
        let accessoryHeight: CGFloat = includesCurrentPassword ? 220 : 188
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: accessoryHeight))

        var y = accessoryHeight - 28

        func makeLabel(_ text: String, y: CGFloat) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.frame = NSRect(x: 0, y: y, width: 360, height: 16)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        }

        if includesCurrentPassword {
            accessoryView.addSubview(makeLabel("Current Passphrase", y: y))
            y -= 24
            let currentField = NSSecureTextField(frame: NSRect(x: 0, y: y, width: 360, height: 24))
            currentField.placeholderString = "Current Passphrase"
            accessoryView.addSubview(currentField)
            y -= 36

            accessoryView.addSubview(makeLabel("New Passphrase", y: y))
            y -= 24
            let passphraseField = NSSecureTextField(frame: NSRect(x: 0, y: y, width: 360, height: 24))
            passphraseField.placeholderString = "New Passphrase"
            accessoryView.addSubview(passphraseField)
            y -= 32
            let verifyField = NSSecureTextField(frame: NSRect(x: 0, y: y, width: 360, height: 24))
            verifyField.placeholderString = "Verify New Passphrase"
            accessoryView.addSubview(verifyField)

            configureAdvancedPassphraseControls(
                in: accessoryView,
                startY: y - 56,
                alert: alert,
                passphraseField: passphraseField,
                verifyField: verifyField,
                currentField: currentField
            )

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            guard passphraseField.stringValue == verifyField.stringValue,
                  !passphraseField.stringValue.isEmpty,
                  let passphraseData = passphraseField.stringValue.data(using: .utf8),
                  !currentField.stringValue.isEmpty,
                  let currentPassphraseData = currentField.stringValue.data(using: .utf8) else {
                preferences.legacyStorage.lastLoadSummary = "Invalid passphrase"
                preferences.legacyStorage.lastLoadDetail = "The entered passphrases were empty or did not match."
                return nil
            }

            let rememberButton = accessoryView.subviews.compactMap { $0 as? NSButton }.first
            let popup = accessoryView.subviews.compactMap { $0 as? NSPopUpButton }.first
            let fields = accessoryView.subviews.compactMap { $0 as? NSTextField }.filter { $0.isEditable }
            let iterationsField = fields.first

            return LegacyPassphraseDialogResult(
                passphraseData: passphraseData,
                rememberInKeychain: rememberButton?.state == .on,
                hashIterationCount: validatedHashIterations(from: iterationsField?.stringValue),
                keyLengthInBits: popup?.selectedTag() ?? preferences.legacyStorage.keyLengthInBits,
                currentPassphraseData: currentPassphraseData
            )
        } else {
            accessoryView.addSubview(makeLabel("Passphrase", y: y))
            y -= 24
            let passphraseField = NSSecureTextField(frame: NSRect(x: 0, y: y, width: 360, height: 24))
            passphraseField.placeholderString = "Passphrase"
            accessoryView.addSubview(passphraseField)
            y -= 32
            let verifyField = NSSecureTextField(frame: NSRect(x: 0, y: y, width: 360, height: 24))
            verifyField.placeholderString = "Verify Passphrase"
            accessoryView.addSubview(verifyField)

            configureAdvancedPassphraseControls(
                in: accessoryView,
                startY: y - 56,
                alert: alert,
                passphraseField: passphraseField,
                verifyField: verifyField,
                currentField: nil
            )

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            guard passphraseField.stringValue == verifyField.stringValue,
                  !passphraseField.stringValue.isEmpty,
                  let passphraseData = passphraseField.stringValue.data(using: .utf8) else {
                preferences.legacyStorage.lastLoadSummary = "Invalid passphrase"
                preferences.legacyStorage.lastLoadDetail = "The entered passphrases were empty or did not match."
                return nil
            }

            let rememberButton = accessoryView.subviews.compactMap { $0 as? NSButton }.first
            let popup = accessoryView.subviews.compactMap { $0 as? NSPopUpButton }.first
            let fields = accessoryView.subviews.compactMap { $0 as? NSTextField }.filter { $0.isEditable }
            let iterationsField = fields.first

            return LegacyPassphraseDialogResult(
                passphraseData: passphraseData,
                rememberInKeychain: rememberButton?.state == .on,
                hashIterationCount: validatedHashIterations(from: iterationsField?.stringValue),
                keyLengthInBits: popup?.selectedTag() ?? preferences.legacyStorage.keyLengthInBits,
                currentPassphraseData: nil
            )
        }
    }

    private func validatedHashIterations(from string: String?) -> Int {
        guard let string, let rawValue = Int(string) else {
            return preferences.legacyStorage.hashIterationCount
        }
        return min(max(rawValue, 2000), 250000)
    }

    private func configureAdvancedPassphraseControls(
        in view: NSView,
        startY: CGFloat,
        alert: NSAlert,
        passphraseField: NSSecureTextField,
        verifyField: NSSecureTextField,
        currentField: NSSecureTextField?
    ) {
        let y = startY
        let advancedHelp = NSTextField(labelWithString: "Advanced key-derivation settings")
        advancedHelp.frame = NSRect(x: 0, y: y + 34, width: 360, height: 16)
        advancedHelp.font = .systemFont(ofSize: 11, weight: .semibold)
        advancedHelp.textColor = .secondaryLabelColor
        view.addSubview(advancedHelp)

        let advancedBox = NSBox(frame: NSRect(x: 0, y: 0, width: 360, height: 78))
        advancedBox.boxType = .custom
        advancedBox.cornerRadius = 6
        advancedBox.borderColor = .separatorColor
        advancedBox.fillColor = .clear

        let iterationsLabel = NSTextField(labelWithString: "PBKDF2 iterations")
        iterationsLabel.frame = NSRect(x: 12, y: 46, width: 120, height: 16)
        iterationsLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        iterationsLabel.textColor = .secondaryLabelColor

        let iterationsField = NSTextField(frame: NSRect(x: 136, y: 40, width: 120, height: 24))
        iterationsField.stringValue = "\(preferences.legacyStorage.hashIterationCount)"
        let iterationsHint = NSTextField(labelWithString: "2000 - 250000")
        iterationsHint.frame = NSRect(x: 262, y: 44, width: 86, height: 16)
        iterationsHint.font = .systemFont(ofSize: 11)
        iterationsHint.alignment = .right
        iterationsHint.textColor = .secondaryLabelColor

        let keyLengthLabel = NSTextField(labelWithString: "Key length")
        keyLengthLabel.frame = NSRect(x: 12, y: 16, width: 120, height: 16)
        keyLengthLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        keyLengthLabel.textColor = .secondaryLabelColor

        let keyLengthPopup = NSPopUpButton(frame: NSRect(x: 136, y: 10, width: 120, height: 26), pullsDown: false)
        keyLengthPopup.addItem(withTitle: "128 bits")
        keyLengthPopup.lastItem?.tag = 128
        keyLengthPopup.addItem(withTitle: "192 bits")
        keyLengthPopup.lastItem?.tag = 192
        keyLengthPopup.addItem(withTitle: "256 bits")
        keyLengthPopup.lastItem?.tag = 256
        keyLengthPopup.selectItem(withTag: preferences.legacyStorage.keyLengthInBits)

        advancedBox.addSubview(iterationsLabel)
        advancedBox.addSubview(iterationsField)
        advancedBox.addSubview(iterationsHint)
        advancedBox.addSubview(keyLengthLabel)
        advancedBox.addSubview(keyLengthPopup)
        view.addSubview(advancedBox)

        let rememberButton = NSButton(checkboxWithTitle: "Remember passphrase in Keychain", target: nil, action: nil)
        rememberButton.frame = NSRect(x: 0, y: 0, width: 360, height: 18)
        rememberButton.state = preferences.legacyStorage.storesPasswordInKeychain ? .on : .off
        view.addSubview(rememberButton)

        alert.accessoryView = view
        alert.buttons.first?.isEnabled = true
    }

    private func recoverySource(for source: LegacySingleDatabaseLoadSource) -> LegacyRecoverySource {
        switch source {
        case .database: .database
        case .journal: .journal
        case .backup: .backup
        }
    }

    private func syncDirectoryMonitoring() {
        pendingDirectoryReloadWorkItem?.cancel()

        guard preferences.legacyStorage.backend == .legacyFileDirectory,
              preferences.legacyStorage.reloadsFromDiskOnActivate,
              let directoryURL = resolvedNotesDirectoryURL() else {
            directoryMonitor.stop()
            return
        }

        directoryMonitor.startMonitoring(path: directoryURL.path) { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.scheduleDirectoryReload()
            }
        }
    }

    private func scheduleDirectoryReload() {
        guard Date() >= suppressDirectoryRefreshUntil else { return }

        pendingDirectoryReloadWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard Date() >= self.suppressDirectoryRefreshUntil else { return }
            self.importNotesFromConfiguredDirectory(preserveUIState: true)
        }
        pendingDirectoryReloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func suppressDirectoryRefresh(for seconds: TimeInterval) {
        suppressDirectoryRefreshUntil = Date().addingTimeInterval(seconds)
    }

    private func applyInternalPreferencesChange(_ changes: () -> Void) {
        isApplyingInternalPreferencesChange = true
        changes()
        isApplyingInternalPreferencesChange = false
    }

    private func resolvedNotesDirectoryURL() -> URL? {
        if let bookmarkData = preferences.legacyStorage.notesDirectoryBookmarkData {
            var isStale = false
            if let resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return resolvedURL
            }
        }

        guard !preferences.legacyStorage.notesDirectoryPath.isEmpty else { return nil }
        return URL(fileURLWithPath: preferences.legacyStorage.notesDirectoryPath, isDirectory: true)
    }
}
