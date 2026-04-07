import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            SearchCreateBar()
            Divider()
            splitContent
        }
        .background(Color(nsColor: NSColor.windowBackgroundColor))
        .transaction { transaction in
            transaction.animation = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.reloadNotesFromDiskIfNeeded()
        }
        .alert("Delete selected notes?", isPresented: $appState.isShowingDeletionConfirmation) {
            Button("Delete", role: .destructive) {
                appState.deletePendingNotes()
            }
            Button("Cancel", role: .cancel) {
                appState.cancelPendingDeletion()
            }
        } message: {
            Text("Press Command-Z afterward to undo note-body edits for the currently selected note.")
        }
    }

    @ViewBuilder
    private var splitContent: some View {
        switch appState.preferences.layoutStyle {
        case .horizontal:
            HSplitView {
                BrowserPane()
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                EditorPane()
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        case .vertical:
            VSplitView {
                BrowserPane()
                    .frame(minHeight: 220, idealHeight: 280)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                EditorPane()
                    .frame(minHeight: 260)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct SearchCreateBar: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            AppKitControlField(
                text: appState.controlFieldText,
                placeholder: "Search or Create",
                selectAllOnBeginEditing: appState.shouldSelectAllControlFieldTextOnFocus,
                isEditingTitle: appState.isEditingTitleInControlField,
                autoComplete: { value in
                    appState.autoCompleteControlField(value)
                },
                onChange: { value in
                    appState.updateControlField(value)
                },
                onSubmit: {
                    appState.submitControlField()
                },
                onCancel: {
                    appState.cancelControlFieldAction()
                },
                onMoveForward: {
                    appState.moveForwardFromControlField()
                },
                onMoveBackward: {
                    appState.moveBackwardFromControlField()
                },
                onMoveToEditor: {
                    appState.commitControlFieldRenameAndFocusEditor()
                }
            )
            .frame(height: 24)

            Menu {
                ForEach(appState.syncStates) { state in
                    Label(state.detail, systemImage: iconName(for: state.status))
                }
            } label: {
                Image(systemName: statusImageName)
                    .foregroundStyle(statusColor)
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 36)
    }

    private var statusImageName: String {
        if appState.syncStates.contains(where: { $0.status == .error }) {
            return "exclamationmark.triangle.fill"
        }
        if appState.syncStates.contains(where: { $0.status == .syncing }) {
            return "arrow.triangle.2.circlepath.circle.fill"
        }
        return "chevron.down.circle"
    }

    private var statusColor: Color {
        if appState.syncStates.contains(where: { $0.status == .error }) {
            return .orange
        }
        if appState.syncStates.contains(where: { $0.status == .syncing }) {
            return .accentColor
        }
        return .secondary
    }

    private func iconName(for status: SyncServiceState.Status) -> String {
        switch status {
        case .idle: "checkmark.circle"
        case .syncing: "arrow.triangle.2.circlepath"
        case .error: "exclamationmark.triangle"
        }
    }
}

private struct BrowserPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            BrowserModeBar()
            Divider()
            BrowserContentView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BrowserModeBar: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Notes") {
                    appState.sidebarMode = .notes
                }
                Button("Tags") {
                    appState.sidebarMode = .tags
                }
                Button("Bookmarks") {
                    appState.sidebarMode = .bookmarks
                }
                Button("Saved Searches") {
                    appState.sidebarMode = .savedSearches
                }
            } label: {
                HStack(spacing: 4) {
                    Text(title(for: appState.sidebarMode))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)

            Spacer()

            Text(countText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func title(for mode: SidebarMode) -> String {
        switch mode {
        case .notes: "Notes"
        case .tags: "Tags"
        case .bookmarks: "Bookmarks"
        case .savedSearches: "Saved Searches"
        }
    }

    private var countText: String {
        switch appState.sidebarMode {
        case .notes:
            "\(appState.filteredNotes.count)"
        case .tags:
            "\(appState.tags.count)"
        case .bookmarks:
            "\(appState.bookmarks.count)"
        case .savedSearches:
            "\(appState.savedSearches.count)"
        }
    }
}

private struct BrowserContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        switch appState.sidebarMode {
        case .notes:
            NotesListView()
        case .tags:
            TagsListView()
        case .bookmarks:
            BookmarksListView()
        case .savedSearches:
            SavedSearchesListView()
        }
    }
}

private struct NotesListView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        AppKitNotesTableView(
            notes: appState.filteredNotes,
            selectedNoteID: appState.selectedNoteID,
            showsPreviewInTitleColumn: appState.preferences.showsPreviewInTitleColumn,
            tableTitleFontSize: appState.preferences.tableTitleFontSize,
            tablePreviewFontSize: appState.preferences.tablePreviewFontSize,
            tableMetadataFontSize: appState.preferences.tableMetadataFontSize,
            refreshGeneration: appState.browserRefreshGeneration,
            sortField: appState.preferences.sortField,
            sortReversed: appState.preferences.sortReversed,
            onSelectNote: { noteID in
                appState.select(noteID: noteID)
            },
            onSort: { field in
                appState.setSortField(field)
            },
            onMoveForward: {
                appState.moveForwardFromNotesList()
            },
            onMoveBackward: {
                appState.moveBackwardFromNotesList()
            }
        )
        .id(appState.browserRefreshGeneration)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TagsListView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
            ForEach(appState.tags) { tag in
                Button {
                    appState.select(tag: tag.name)
                } label: {
                    HStack {
                        Text(tag.name)
                            .font(.system(size: 12))
                        Spacer()
                        Text("\(tag.noteCount)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selectionBackground(isSelected: appState.sidebarMode == .tags && appState.selectedTag == tag.name))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
    }
}

private struct BookmarksListView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
            ForEach(appState.bookmarks) { bookmark in
                Button {
                    appState.restore(bookmark: bookmark)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bookmark.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !bookmark.searchString.isEmpty {
                            Text(bookmark.searchString)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selectionBackground(isSelected: appState.sidebarMode == .bookmarks && appState.searchText == bookmark.searchString && appState.selectedNoteID == bookmark.noteID))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Delete Bookmark") {
                        appState.removeBookmark(bookmark)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if appState.bookmarks.isEmpty {
                SourceEmptyState(message: "No bookmarks")
            }
        }
    }
}

private struct SavedSearchesListView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
            ForEach(appState.savedSearches) { item in
                Button {
                    appState.select(savedSearch: item)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(item.query)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selectionBackground(
                        isSelected: appState.sidebarMode == .savedSearches &&
                            appState.searchText == item.query &&
                            item.selectedNoteID.map { $0 == appState.selectedNoteID } ?? true
                    ))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Delete Saved Search") {
                        appState.removeSavedSearch(item)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if appState.savedSearches.isEmpty {
                SourceEmptyState(message: "No saved searches")
            }
        }
    }
}

private func selectionBackground(isSelected: Bool) -> some View {
    RoundedRectangle(cornerRadius: 4)
        .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
}

private struct SourceEmptyState: View {
    let message: String

    var body: some View {
        VStack {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

private struct EditorPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let note = appState.selectedNote {
                NoteEditorView(note: note)
            } else {
                Color(nsColor: appState.preferences.backgroundColor.nsColor)
            }

            if appState.selectedNote == nil {
                EmptyEditorState()
                    .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appState.preferences.backgroundColor.nsColor))
    }
}

private struct EmptyEditorState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No Note Selected")
                .font(.system(size: 14, weight: .semibold))
            Text("Type in the control field to search or create.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

private struct NoteEditorView: View {
    @EnvironmentObject private var appState: AppState
    let note: Note
    @State private var labelsText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            AppKitNoteTextView(
                noteID: note.id,
                attributedText: note.body,
                selection: note.selectedRange,
                fontName: appState.preferences.noteBodyFontName,
                fontSize: appState.preferences.noteBodyFontSize,
                foregroundColor: appState.preferences.foregroundColor.nsColor,
                backgroundColor: appState.preferences.backgroundColor.nsColor,
                isEditable: !appState.isCurrentBackendReadOnly,
                refreshGeneration: appState.editorRefreshGeneration,
                searchHighlightTerms: appState.activeSearchHighlightTerms,
                searchHighlightColor: appState.preferences.searchHighlightColor.nsColor,
                onBeginEditing: {},
                onTextChange: { body, range in
                    appState.updateCurrentNoteBody(body, selectedRange: range)
                },
                onSelectionChange: { range in
                    appState.updateCurrentNoteSelection(range)
                },
                onUndoCommand: {
                    appState.undoCurrentNote()
                },
                onRedoCommand: {
                    appState.redoCurrentNote()
                },
                onMoveToTitleEditing: {
                    appState.beginRenamingSelectedNoteInControlField()
                },
                onMoveToTagEditing: {
                    appState.focusTagEditor()
                }
            )
            .id(note.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 8) {
                Text("Tags")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                AppKitTagField(
                    text: labelsText,
                    isEditable: !appState.isCurrentBackendReadOnly,
                    focusRequestID: appState.tagEditorFocusRequestID,
                    onChange: { value in
                        labelsText = value
                    },
                    onSubmit: {
                        appState.updateLabelsForCurrentNote(labelsText)
                    },
                    onMoveForward: {
                        appState.moveForwardFromTagEditor()
                    },
                    onMoveBackward: {
                        appState.moveBackwardFromTagEditor()
                    },
                    onCancel: {
                        labelsText = note.labelsText
                        appState.moveBackwardFromTagEditor()
                    }
                )
                .frame(maxWidth: .infinity)

                if appState.isCurrentBackendReadOnly {
                    Text("Read only")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onAppear {
            labelsText = note.labelsText
        }
        .onChange(of: note.id) { _, _ in
            labelsText = note.labelsText
        }
        .onChange(of: note.labelsText) { _, newValue in
            labelsText = newValue
        }
    }
}

struct PreferencesRootView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var fontPanelController = PreferencesFontPanelController()

    var body: some View {
        VStack(spacing: 0) {
            PreferencesToolbar(selectedPane: selectedPaneBinding)
            Divider()
            paneContent
                .id(selectedPane.rawValue)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedPane {
        case .general:
            generalPane
        case .editing:
            editingPane
        case .fonts:
            fontsPane
        case .database:
            databasePane
        case .security:
            securityPane
        }
    }

    private var selectedPane: PreferencesPane {
        PreferencesPane(rawValue: appState.preferences.lastSelectedPreferencesPane) ?? .general
    }

    private var selectedPaneBinding: Binding<PreferencesPane> {
        Binding(
            get: { selectedPane },
            set: { appState.preferences.lastSelectedPreferencesPane = $0.rawValue }
        )
    }

    private var generalPane: some View {
        Form {
            Section("General") {
                Picker("Layout", selection: $appState.preferences.layoutStyle) {
                    Text("Vertical").tag(LayoutStyle.vertical)
                    Text("Horizontal").tag(LayoutStyle.horizontal)
                }

                Toggle("Confirm deletion", isOn: $appState.preferences.confirmDeletion)
                Toggle("Auto-complete searches", isOn: $appState.preferences.autoCompleteSearches)
                Toggle("Quit when closing window", isOn: $appState.preferences.quitWhenClosingWindow)
                Toggle("Show previews in title column", isOn: $appState.preferences.showsPreviewInTitleColumn)
            }

            Section("Browser Defaults") {
                Picker("Sort notes by", selection: $appState.preferences.sortField) {
                    ForEach(NoteSortField.allCases) { field in
                        Text(field.displayName).tag(field)
                    }
                }

                Toggle("Reverse sort order", isOn: $appState.preferences.sortReversed)
            }

            Section("Activation Hotkey") {
                PreferenceStatusRow(label: "Current shortcut", value: appState.activationHotKeyDisplayString)

                HStack {
                    Button("Record Shortcut...") {
                        appState.recordActivationHotKey()
                    }

                    Button("Disable Shortcut") {
                        appState.clearActivationHotKey()
                    }
                    .disabled(!appState.preferences.activationHotKey.isEnabled)
                }

                Text("This global shortcut toggles Notation to the foreground, closer to the original app’s activation hotkey behavior.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var editingPane: some View {
        Form {
            Section("Editing") {
                Toggle("Check spelling", isOn: $appState.preferences.checkSpelling)
                Toggle("Soft tabs", isOn: $appState.preferences.softTabs)
                HStack {
                    Text("Tab width")
                    Spacer()
                    Stepper(value: $appState.preferences.tabWidth, in: 2...8, step: 1) {
                        Text("\(appState.preferences.tabWidth) spaces")
                            .foregroundStyle(.secondary)
                    }
                    .labelsHidden()
                }
                Toggle("Paste preserves style", isOn: $appState.preferences.pastePreservesStyle)
                Toggle("Make URLs clickable", isOn: $appState.preferences.makeURLsClickable)
                Toggle("Auto-suggest links", isOn: $appState.preferences.linksAutoSuggested)
                Toggle("Highlight search terms", isOn: $appState.preferences.highlightsSearchTerms)
                Toggle("Secure text entry", isOn: $appState.preferences.secureTextEntry)
            }
        }
        .formStyle(.grouped)
    }

    private var fontsPane: some View {
        Form {
            Section("Fonts & Colors") {
                HStack {
                    Text("Body font")
                    Spacer()
                    Text(bodyFontSummary)
                        .foregroundStyle(.secondary)
                    Button("Choose Font...") {
                        fontPanelController.present(
                            currentFont: NSFont(
                                name: appState.preferences.noteBodyFontName,
                                size: appState.preferences.noteBodyFontSize
                            ) ?? .monospacedSystemFont(ofSize: appState.preferences.noteBodyFontSize, weight: .regular)
                        ) { selectedFont in
                            appState.setNoteBodyFont(selectedFont)
                        }
                    }
                }
                HStack {
                    Text("Body font size")
                    Spacer()
                    Stepper(value: $appState.preferences.noteBodyFontSize, in: 11...22, step: 1) {
                        Text("\(Int(appState.preferences.noteBodyFontSize))")
                            .foregroundStyle(.secondary)
                    }
                    .labelsHidden()
                }
                HStack {
                    Text("List title font size")
                    Spacer()
                    Stepper(value: $appState.preferences.tableTitleFontSize, in: 10...18, step: 1) {
                        Text("\(Int(appState.preferences.tableTitleFontSize))")
                            .foregroundStyle(.secondary)
                    }
                    .labelsHidden()
                }
                HStack {
                    Text("List preview font size")
                    Spacer()
                    Stepper(value: $appState.preferences.tablePreviewFontSize, in: 9...16, step: 1) {
                        Text("\(Int(appState.preferences.tablePreviewFontSize))")
                            .foregroundStyle(.secondary)
                    }
                    .labelsHidden()
                }
                HStack {
                    Text("List metadata font size")
                    Spacer()
                    Stepper(value: $appState.preferences.tableMetadataFontSize, in: 9...16, step: 1) {
                        Text("\(Int(appState.preferences.tableMetadataFontSize))")
                            .foregroundStyle(.secondary)
                    }
                    .labelsHidden()
                }
                ColorPicker("Foreground", selection: Binding(
                    get: {
                        Color(
                            red: appState.preferences.foregroundColor.red,
                            green: appState.preferences.foregroundColor.green,
                            blue: appState.preferences.foregroundColor.blue,
                            opacity: appState.preferences.foregroundColor.alpha
                        )
                    },
                    set: { color in
                        appState.preferences.foregroundColor = color.toColorValue()
                    }
                ))
                ColorPicker("Background", selection: Binding(
                    get: {
                        Color(
                            red: appState.preferences.backgroundColor.red,
                            green: appState.preferences.backgroundColor.green,
                            blue: appState.preferences.backgroundColor.blue,
                            opacity: appState.preferences.backgroundColor.alpha
                        )
                    },
                    set: { color in
                        appState.preferences.backgroundColor = color.toColorValue()
                    }
                ))
                ColorPicker("Search highlight", selection: Binding(
                    get: {
                        Color(
                            red: appState.preferences.searchHighlightColor.red,
                            green: appState.preferences.searchHighlightColor.green,
                            blue: appState.preferences.searchHighlightColor.blue,
                            opacity: appState.preferences.searchHighlightColor.alpha
                        )
                    },
                    set: { color in
                        appState.preferences.searchHighlightColor = color.toColorValue()
                    }
                ))

                Text("The body font chooser uses the standard macOS font panel. Bold and italic defaults are normalized back to the regular family variant, matching the original app more closely.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Text("List title, preview, and metadata fonts are now independently adjustable so the browser density can be tuned closer to the original table view.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var databasePane: some View {
        Form {
            Section("Storage") {
                Picker("Backend", selection: Binding(
                    get: { appState.preferences.legacyStorage.backend },
                    set: { appState.setStorageBackend($0) }
                )) {
                    ForEach(StorageBackendKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }

                Picker("New file format", selection: $appState.preferences.noteStorageFormat) {
                    Text("Plain Text (.txt)").tag("Plain Text (.txt)")
                    Text("Rich Text (.rtf)").tag("Rich Text (.rtf)")
                    Text("HTML (.html)").tag("HTML (.html)")
                    Text("Markdown (.md)").tag("Markdown (.md)")
                }
                .disabled(appState.preferences.legacyStorage.backend != .legacyFileDirectory)

                HStack {
                    Text("Notes directory")
                    Spacer()
                    Text(appState.preferences.legacyStorage.notesDirectoryPath.isEmpty ? "Not configured" : appState.preferences.legacyStorage.notesDirectoryPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack {
                    Button("Choose Notes Folder...") {
                        appState.chooseNotesDirectory()
                    }
                    .disabled(
                        appState.preferences.legacyStorage.backend != .legacyFileDirectory &&
                        appState.preferences.legacyStorage.backend != .legacySingleDatabase
                    )

                    Button("Reveal in Finder") {
                        appState.revealNotesDirectoryInFinder()
                    }
                    .disabled(appState.preferences.legacyStorage.notesDirectoryPath.isEmpty)
                }

                HStack {
                    Button("Reload From Active Storage") {
                        appState.reloadNotesFromActiveStorage()
                    }
                    .disabled(
                        (appState.preferences.legacyStorage.backend == .legacyFileDirectory ||
                        appState.preferences.legacyStorage.backend == .legacySingleDatabase) &&
                        appState.preferences.legacyStorage.notesDirectoryPath.isEmpty
                    )

                    Button("Migrate Current Notes To Folder") {
                        appState.migrateCurrentNotesToConfiguredDirectory()
                    }
                    .disabled(appState.preferences.legacyStorage.notesDirectoryPath.isEmpty)
                }

                if appState.preferences.legacyStorage.backend == .legacyFileDirectory {
                    Button("Import Notes From Folder") {
                        appState.importNotesFromConfiguredDirectory()
                    }
                    .disabled(appState.preferences.legacyStorage.notesDirectoryPath.isEmpty)

                    Button("Repair Selected Text Encoding...") {
                        appState.promptToRepairSelectedNoteEncoding()
                    }
                    .disabled(!appState.canRepairSelectedNoteEncoding)
                }

                if appState.preferences.legacyStorage.backend == .legacySingleDatabase {
                    Button("Load Legacy Database") {
                        appState.loadNotesFromLegacySingleDatabase()
                    }
                    .disabled(appState.preferences.legacyStorage.notesDirectoryPath.isEmpty)
                }

                HStack {
                    Text("Database file")
                    Spacer()
                    Text(appState.preferences.legacyStorage.databaseFileName)
                        .foregroundStyle(.secondary)
                }
                Toggle("Reload file-backed notes on activate", isOn: $appState.preferences.legacyStorage.reloadsFromDiskOnActivate)
            }

            Section("Recovery") {
                Button("Recover Legacy Database From Backup") {
                    appState.recoverLegacySingleDatabaseFromBackup()
                }
                .disabled(!appState.canRecoverLegacySingleDatabase)

                Button("Recover Legacy Database From Journal") {
                    appState.recoverLegacySingleDatabaseFromJournal()
                }
                .disabled(!appState.canRecoverLegacySingleDatabaseJournal)

                Button("Commit Recovered Archive To Notes & Settings") {
                    appState.commitRecoveredLegacySingleDatabase()
                }
                .disabled(!appState.canCommitRecoveredLegacySingleDatabase)
            }

            Section("Legacy Storage Status") {
                PreferenceStatusRow(label: "Migration state", value: migrationStateText(appState.preferences.legacyStorage.migrationState))
                PreferenceStatusRow(label: "Legacy read support", value: booleanStatus(appState.preferences.legacyStorage.supportsLegacyRead))
                PreferenceStatusRow(label: "Legacy write support", value: booleanStatus(appState.preferences.legacyStorage.supportsLegacyWrite))
                PreferenceStatusRow(label: "Directory sync", value: booleanStatus(appState.preferences.legacyStorage.supportsDirectorySync))
                PreferenceStatusRow(label: "Journaling", value: booleanStatus(appState.preferences.legacyStorage.supportsJournaling))
                PreferenceStatusRow(label: "Backup snapshot", value: appState.canRecoverLegacySingleDatabase ? "Available" : "None")
                PreferenceStatusRow(label: "Pending journal", value: appState.canRecoverLegacySingleDatabaseJournal ? "Available" : "None")
                PreferenceStatusRow(label: "External file import", value: booleanStatus(appState.preferences.legacyStorage.supportsExternalFileImport))
                PreferenceStatusRow(label: "Formats", value: appState.preferences.legacyStorage.supportedFormats.joined(separator: ", "))
                PreferenceStatusRow(label: "Last load", value: appState.preferences.legacyStorage.lastLoadSummary)
                if !appState.preferences.legacyStorage.lastLoadDetail.isEmpty {
                    Text(appState.preferences.legacyStorage.lastLoadDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var securityPane: some View {
        Form {
            Section("Note Database Security") {
                HStack {
                    Text("Encryption")
                    Spacer()
                    Text(appState.preferences.legacyStorage.encryptionEnabled ? "Enabled" : "Disabled")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button(appState.preferences.legacyStorage.encryptionEnabled ? "Change Passphrase..." : "Enable Encryption...") {
                        if appState.preferences.legacyStorage.encryptionEnabled {
                            appState.changeLegacyDatabasePassphrase()
                        } else {
                            appState.enableLegacyDatabaseEncryption()
                        }
                    }
                    .disabled(!appState.canConfigureLegacyDatabaseEncryption)

                    if appState.preferences.legacyStorage.encryptionEnabled {
                        Button("Disable Encryption") {
                            appState.disableLegacyDatabaseEncryption()
                        }
                        .disabled(!appState.canConfigureLegacyDatabaseEncryption)
                    }
                }

                Toggle(
                    "Remember passphrase in Keychain",
                    isOn: Binding(
                        get: { appState.preferences.legacyStorage.storesPasswordInKeychain },
                        set: { appState.setLegacyDatabaseStoresPasswordInKeychain($0) }
                    )
                )
                .disabled(!appState.preferences.legacyStorage.encryptionEnabled)

                PreferenceStatusRow(label: "Keychain status", value: appState.hasLegacyDatabasePassphraseInKeychain ? "Stored" : "Not Stored")
                PreferenceStatusRow(label: "Last action", value: appState.preferences.legacyStorage.lastLoadSummary)
                if !appState.preferences.legacyStorage.lastLoadDetail.isEmpty {
                    Text(appState.preferences.legacyStorage.lastLoadDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Key Derivation") {
                HStack {
                    Text("PBKDF2 iterations")
                    Spacer()
                    Stepper(value: $appState.preferences.legacyStorage.hashIterationCount, in: 1000...50000, step: 1000) {
                        Text("\(appState.preferences.legacyStorage.hashIterationCount)")
                            .foregroundStyle(.secondary)
                    }
                    .labelsHidden()
                }
                .disabled(appState.preferences.legacyStorage.encryptionEnabled)

                Picker("Key length", selection: $appState.preferences.legacyStorage.keyLengthInBits) {
                    Text("128 bits").tag(128)
                    Text("192 bits").tag(192)
                    Text("256 bits").tag(256)
                }
                .disabled(appState.preferences.legacyStorage.encryptionEnabled)

                Text(appState.preferences.legacyStorage.encryptionEnabled
                     ? "Key derivation settings are locked while encryption is enabled so the current archive remains readable."
                     : "These settings will be used the next time encryption is enabled or the passphrase is changed.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Section("External Editors") {
                Button("Add External Editor...") {
                    appState.chooseExternalEditor()
                }

                if appState.preferences.legacyStorage.externalEditors.isEmpty {
                    Text("No external editors configured.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.preferences.legacyStorage.externalEditors) { editor in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(editor.name)
                                Text(editor.bundlePath)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if editor.isDefault {
                                Text("Default")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            } else {
                                Button("Make Default") {
                                    appState.makeExternalEditorDefault(editor.id)
                                }
                            }
                            Button("Remove") {
                                appState.removeExternalEditor(editor.id)
                            }
                        }
                    }
                }
            }

            Section("Current Coverage") {
                Text("Legacy database encryption, keychain storage, key-derivation settings, and external editor configuration are now implemented here. Remaining storage work is in write-ahead logging fidelity rather than the preferences shell itself.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var bodyFontSummary: String {
        "\(appState.preferences.noteBodyFontName) \(Int(appState.preferences.noteBodyFontSize))"
    }
}

private enum PreferencesPane: String, CaseIterable, Hashable {
    case general
    case editing
    case fonts
    case database
    case security

    var title: String {
        switch self {
        case .general: "General"
        case .editing: "Editing"
        case .fonts: "Fonts & Colors"
        case .database: "Database"
        case .security: "Security"
        }
    }

    var iconName: String {
        switch self {
        case .general: "gearshape"
        case .editing: "character.cursor.ibeam"
        case .fonts: "paintpalette"
        case .database: "internaldrive"
        case .security: "lock.shield"
        }
    }
}

private struct PreferencesToolbar: View {
    @Binding var selectedPane: PreferencesPane

    var body: some View {
        HStack(spacing: 10) {
            ForEach(PreferencesPane.allCases, id: \.self) { pane in
                PreferenceToolbarButton(
                    pane: pane,
                    isSelected: selectedPane == pane,
                    action: { selectedPane = pane }
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct PreferenceToolbarButton: View {
    let pane: PreferencesPane
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: pane.iconName)
                    .font(.system(size: 16, weight: .semibold))
                Text(pane.title)
                    .font(.system(size: 11, weight: .medium))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.primary)
            .frame(width: 116, height: 66)
            .background(background)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .frame(width: 116, height: 66)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var background: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor).opacity(0.01))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
            )
    }
}

private final class PreferencesFontPanelController: NSObject, ObservableObject {
    private var onFontChange: ((NSFont) -> Void)?
    private var fallbackFont: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)

    func present(currentFont: NSFont, onFontChange: @escaping (NSFont) -> Void) {
        self.onFontChange = onFontChange
        self.fallbackFont = currentFont

        let manager = NSFontManager.shared
        manager.target = self
        manager.setSelectedFont(currentFont, isMultiple: false)
        manager.orderFrontFontPanel(nil)
    }

    @objc
    func changeFont(_ sender: Any?) {
        let manager = NSFontManager.shared
        let selectedFont = manager.selectedFont ?? fallbackFont
        var updatedFont = manager.convert(selectedFont)
        updatedFont = manager.convert(updatedFont, toNotHaveTrait: .boldFontMask)
        updatedFont = manager.convert(updatedFont, toNotHaveTrait: .italicFontMask)
        fallbackFont = updatedFont
        onFontChange?(updatedFont)
    }
}

private struct PreferenceStatusRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

private extension Color {
    func toColorValue() -> ColorValue {
        let nsColor = NSColor(self)
            .usingColorSpace(.deviceRGB) ?? .textColor
        return ColorValue(
            red: Double(nsColor.redComponent),
            green: Double(nsColor.greenComponent),
            blue: Double(nsColor.blueComponent),
            alpha: Double(nsColor.alphaComponent)
        )
    }
}

private func booleanStatus(_ value: Bool) -> String {
    value ? "Available" : "Not Yet"
}

private func migrationStateText(_ value: LegacyMigrationState) -> String {
    switch value {
    case .notStarted: "Not Started"
    case .scaffolded: "Scaffolded"
    case .partiallyIntegrated: "Partially Integrated"
    case .integrated: "Integrated"
    }
}
