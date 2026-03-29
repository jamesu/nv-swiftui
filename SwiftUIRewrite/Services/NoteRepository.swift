import AppKit
import Foundation

protocol NoteRepository {
    var notes: [Note] { get }
    var bookmarks: [NoteBookmark] { get }
    var savedSearches: [SavedSearchItem] { get }
    var syncStates: [SyncServiceState] { get }
    var preferences: NVPreferences { get }
    var searchText: String { get }
    var selectedNoteID: UUID? { get }
    var selectedTag: String? { get }
    var sidebarMode: SidebarMode { get }

    func upsert(_ note: Note)
    func remove(noteIDs: Set<UUID>)
    func addBookmark(for note: Note, searchString: String)
    func upsertBookmark(_ bookmark: NoteBookmark)
    func removeBookmark(id: UUID)
    func saveSearch(title: String, query: String, selectedNoteID: UUID?)
    func upsertSavedSearch(_ item: SavedSearchItem)
    func deleteSavedSearch(id: UUID)
    func savePreferences(_ preferences: NVPreferences)
    func saveUIState(searchText: String, selectedNoteID: UUID?, selectedTag: String?, sidebarMode: SidebarMode)
    func replaceAllNotes(_ notes: [Note], selectedNoteID: UUID?)
}

final class InMemoryNoteRepository: NoteRepository {
    private(set) var notes: [Note]
    private(set) var bookmarks: [NoteBookmark]
    private(set) var savedSearches: [SavedSearchItem]
    private(set) var syncStates: [SyncServiceState]
    private(set) var preferences: NVPreferences
    private(set) var searchText: String
    private(set) var selectedNoteID: UUID?
    private(set) var selectedTag: String?
    private(set) var sidebarMode: SidebarMode

    init(
        notes: [Note] = [],
        bookmarks: [NoteBookmark] = [],
        savedSearches: [SavedSearchItem] = [],
        syncStates: [SyncServiceState] = [],
        preferences: NVPreferences = NVPreferences(),
        searchText: String = "",
        selectedNoteID: UUID? = nil,
        selectedTag: String? = nil,
        sidebarMode: SidebarMode = .notes
    ) {
        self.notes = notes
        self.bookmarks = bookmarks
        self.savedSearches = savedSearches
        self.syncStates = syncStates
        self.preferences = preferences
        self.searchText = searchText
        self.selectedNoteID = selectedNoteID
        self.selectedTag = selectedTag
        self.sidebarMode = sidebarMode
    }

    func upsert(_ note: Note) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = note
        } else {
            notes.append(note)
        }
        notes.sort { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.modifiedAt > rhs.modifiedAt
        }
    }

    func remove(noteIDs: Set<UUID>) {
        notes.removeAll { noteIDs.contains($0.id) }
        bookmarks.removeAll { noteIDs.contains($0.noteID) }
        savedSearches = savedSearches.map { search in
            var copy = search
            if let selectedNoteID = copy.selectedNoteID, noteIDs.contains(selectedNoteID) {
                copy.selectedNoteID = nil
            }
            return copy
        }
    }

    func addBookmark(for note: Note, searchString: String) {
        guard !bookmarks.contains(where: { $0.noteID == note.id && $0.searchString == searchString }) else {
            return
        }
        bookmarks.append(NoteBookmark(id: UUID(), noteID: note.id, title: note.title, searchString: searchString))
    }

    func removeBookmark(id: UUID) {
        bookmarks.removeAll { $0.id == id }
    }

    func upsertBookmark(_ bookmark: NoteBookmark) {
        if let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[index] = bookmark
        } else {
            bookmarks.append(bookmark)
        }
    }

    func saveSearch(title: String, query: String, selectedNoteID: UUID?) {
        guard !query.isEmpty else { return }

        if let index = savedSearches.firstIndex(where: { $0.query == query }) {
            savedSearches[index].title = title
            savedSearches[index].selectedNoteID = selectedNoteID
        } else {
            savedSearches.append(SavedSearchItem(id: UUID(), title: title, query: query, selectedNoteID: selectedNoteID))
        }
    }

    func deleteSavedSearch(id: UUID) {
        savedSearches.removeAll { $0.id == id }
    }

    func upsertSavedSearch(_ item: SavedSearchItem) {
        if let index = savedSearches.firstIndex(where: { $0.id == item.id }) {
            savedSearches[index] = item
        } else {
            savedSearches.append(item)
        }
    }

    func savePreferences(_ preferences: NVPreferences) {
        self.preferences = preferences
    }

    func saveUIState(searchText: String, selectedNoteID: UUID?, selectedTag: String?, sidebarMode: SidebarMode) {
        self.searchText = searchText
        self.selectedNoteID = selectedNoteID
        self.selectedTag = selectedTag
        self.sidebarMode = sidebarMode
    }

    func replaceAllNotes(_ notes: [Note], selectedNoteID: UUID?) {
        self.notes = notes
        let validNoteIDs = Set(notes.map(\.id))
        bookmarks.removeAll { !validNoteIDs.contains($0.noteID) }
        savedSearches = savedSearches.map { search in
            var copy = search
            if let noteID = copy.selectedNoteID, !validNoteIDs.contains(noteID) {
                copy.selectedNoteID = nil
            }
            return copy
        }
        self.selectedNoteID = selectedNoteID.flatMap { validNoteIDs.contains($0) ? $0 : nil } ?? notes.first?.id
    }
}

extension InMemoryNoteRepository {
    static func bootstrapLegacySample() -> InMemoryNoteRepository {
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Menlo", size: 14) ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]

        let notes = [
            Note(
                title: "How does this thing work?",
                body: NSAttributedString(
                    string: """
                    Search to narrow the note list.
                    Press Return or begin typing in the editor to create a new note.
                    Use tags to group related notes.
                    """,
                    attributes: bodyAttributes
                ),
                labels: ["help", "reference"]
            ),
            Note(
                title: "Contact details",
                body: NSAttributedString(
                    string: """
                    Jane Example
                    jane@example.com
                    555-0100
                    """,
                    attributes: bodyAttributes
                ),
                labels: ["people"]
            ),
            Note(
                title: "Sprint backlog",
                body: NSAttributedString(
                    string: """
                    - SwiftUI rewrite
                    - Preserve search/create flow
                    - Maintain tag, bookmark, and saved search parity
                    """,
                    attributes: bodyAttributes
                ),
                labels: ["work", "planning"]
            )
        ]

        return InMemoryNoteRepository(
            notes: notes,
            bookmarks: [
                NoteBookmark(id: UUID(), noteID: notes[0].id, title: notes[0].title, searchString: "help")
            ],
            savedSearches: [
                SavedSearchItem(id: UUID(), title: "Planning", query: "rewrite", selectedNoteID: notes[2].id)
            ],
            syncStates: [
                SyncServiceState(id: "disk", displayName: "File Synchronization", status: .idle, detail: "Watching notes folder")
            ],
            preferences: NVPreferences(),
            searchText: "",
            selectedNoteID: notes[0].id,
            selectedTag: nil,
            sidebarMode: .notes
        )
    }
}

final class JSONNoteRepository: NoteRepository {
    private struct PersistedState: Codable {
        var notes: [PersistedNote]
        var bookmarks: [NoteBookmark]
        var savedSearches: [SavedSearchItem]
        var syncStates: [SyncServiceState]
        var preferences: NVPreferences
        var searchText: String
        var selectedNoteID: UUID?
        var selectedTag: String?
        var sidebarMode: SidebarMode
    }

    private struct PersistedNote: Codable {
        var id: UUID
        var title: String
        var plainBody: String
        var attributedBodyRTFBase64: String?
        var labels: [String]
        var createdAt: Date
        var modifiedAt: Date
        var selectedRangeLocation: Int
        var selectedRangeLength: Int
        var filePath: String?
        var syncMetadata: [String: String]
    }

    private(set) var notes: [Note]
    private(set) var bookmarks: [NoteBookmark]
    private(set) var savedSearches: [SavedSearchItem]
    private(set) var syncStates: [SyncServiceState]
    private(set) var preferences: NVPreferences
    private(set) var searchText: String
    private(set) var selectedNoteID: UUID?
    private(set) var selectedTag: String?
    private(set) var sidebarMode: SidebarMode

    private let storageURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(storageURL: URL, seed: InMemoryNoteRepository = .bootstrapLegacySample()) {
        self.storageURL = storageURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        if
            let data = try? Data(contentsOf: storageURL),
            let persisted = try? decoder.decode(PersistedState.self, from: data)
        {
            self.notes = persisted.notes.map(Self.makeNote)
            self.bookmarks = persisted.bookmarks
            self.savedSearches = persisted.savedSearches
            self.syncStates = persisted.syncStates
            self.preferences = persisted.preferences
            self.searchText = persisted.searchText
            self.selectedNoteID = persisted.selectedNoteID
            self.selectedTag = persisted.selectedTag
            self.sidebarMode = persisted.sidebarMode
        } else {
            self.notes = seed.notes
            self.bookmarks = seed.bookmarks
            self.savedSearches = seed.savedSearches
            self.syncStates = seed.syncStates
            self.preferences = seed.preferences
            self.searchText = seed.searchText
            self.selectedNoteID = seed.selectedNoteID
            self.selectedTag = seed.selectedTag
            self.sidebarMode = seed.sidebarMode
            persist()
        }
    }

    static func defaultRepository() -> JSONNoteRepository {
        let baseURL = defaultRepositoryBaseURL()
        return JSONNoteRepository(storageURL: baseURL.appendingPathComponent("state.json"))
    }

    static func defaultRepositoryBaseURL() -> URL {
        let fileManager = FileManager.default
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notation-SwiftUI-Rewrite", isDirectory: true)
        try? fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        return baseURL
    }

    func upsert(_ note: Note) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = note
        } else {
            notes.append(note)
        }
        sortNotes()
        persist()
    }

    func remove(noteIDs: Set<UUID>) {
        notes.removeAll { noteIDs.contains($0.id) }
        bookmarks.removeAll { noteIDs.contains($0.noteID) }
        savedSearches = savedSearches.map { search in
            var copy = search
            if let selectedNoteID = copy.selectedNoteID, noteIDs.contains(selectedNoteID) {
                copy.selectedNoteID = nil
            }
            return copy
        }
        if let selectedNoteID, noteIDs.contains(selectedNoteID) {
            self.selectedNoteID = notes.first?.id
        }
        persist()
    }

    func addBookmark(for note: Note, searchString: String) {
        guard !bookmarks.contains(where: { $0.noteID == note.id && $0.searchString == searchString }) else {
            return
        }
        bookmarks.append(NoteBookmark(id: UUID(), noteID: note.id, title: note.title, searchString: searchString))
        persist()
    }

    func removeBookmark(id: UUID) {
        bookmarks.removeAll { $0.id == id }
        persist()
    }

    func upsertBookmark(_ bookmark: NoteBookmark) {
        if let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[index] = bookmark
        } else {
            bookmarks.append(bookmark)
        }
        persist()
    }

    func saveSearch(title: String, query: String, selectedNoteID: UUID?) {
        guard !query.isEmpty else { return }
        if let index = savedSearches.firstIndex(where: { $0.query == query }) {
            savedSearches[index].title = title
            savedSearches[index].selectedNoteID = selectedNoteID
        } else {
            savedSearches.append(SavedSearchItem(id: UUID(), title: title, query: query, selectedNoteID: selectedNoteID))
        }
        persist()
    }

    func deleteSavedSearch(id: UUID) {
        savedSearches.removeAll { $0.id == id }
        persist()
    }

    func upsertSavedSearch(_ item: SavedSearchItem) {
        if let index = savedSearches.firstIndex(where: { $0.id == item.id }) {
            savedSearches[index] = item
        } else {
            savedSearches.append(item)
        }
        persist()
    }

    func savePreferences(_ preferences: NVPreferences) {
        self.preferences = preferences
        persist()
    }

    func saveUIState(searchText: String, selectedNoteID: UUID?, selectedTag: String?, sidebarMode: SidebarMode) {
        self.searchText = searchText
        self.selectedNoteID = selectedNoteID
        self.selectedTag = selectedTag
        self.sidebarMode = sidebarMode
        persist()
    }

    func replaceAllNotes(_ notes: [Note], selectedNoteID: UUID?) {
        self.notes = notes
        sortNotes()
        let validNoteIDs = Set(notes.map(\.id))
        bookmarks.removeAll { !validNoteIDs.contains($0.noteID) }
        savedSearches = savedSearches.map { search in
            var copy = search
            if let noteID = copy.selectedNoteID, !validNoteIDs.contains(noteID) {
                copy.selectedNoteID = nil
            }
            return copy
        }
        self.selectedNoteID = selectedNoteID.flatMap { validNoteIDs.contains($0) ? $0 : nil } ?? notes.first?.id
        persist()
    }

    private func sortNotes() {
        notes.sort { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.modifiedAt > rhs.modifiedAt
        }
    }

    private func persist() {
        let state = PersistedState(
            notes: notes.map(Self.makePersistedNote),
            bookmarks: bookmarks,
            savedSearches: savedSearches,
            syncStates: syncStates,
            preferences: preferences,
            searchText: searchText,
            selectedNoteID: selectedNoteID,
            selectedTag: selectedTag,
            sidebarMode: sidebarMode
        )

        do {
            let data = try encoder.encode(state)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            fputs("Failed to persist rewrite state: \(error)\n", stderr)
        }
    }

    private static func makePersistedNote(from note: Note) -> PersistedNote {
        let rtfData = try? note.body.data(
            from: NSRange(location: 0, length: note.body.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        return PersistedNote(
            id: note.id,
            title: note.title,
            plainBody: note.plainBody,
            attributedBodyRTFBase64: rtfData?.base64EncodedString(),
            labels: note.labels,
            createdAt: note.createdAt,
            modifiedAt: note.modifiedAt,
            selectedRangeLocation: note.selectedRange.location,
            selectedRangeLength: note.selectedRange.length,
            filePath: note.fileURL?.path,
            syncMetadata: note.syncMetadata
        )
    }

    private static func makeNote(from persisted: PersistedNote) -> Note {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Menlo", size: 14) ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]
        let body: NSAttributedString
        if let encodedRTF = persisted.attributedBodyRTFBase64,
           let data = Data(base64Encoded: encodedRTF),
           let attributed = try? NSAttributedString(data: data, options: [:], documentAttributes: nil) {
            body = attributed
        } else {
            body = NSAttributedString(string: persisted.plainBody, attributes: attributes)
        }
        return Note(
            id: persisted.id,
            title: persisted.title,
            body: body,
            labels: persisted.labels,
            createdAt: persisted.createdAt,
            modifiedAt: persisted.modifiedAt,
            selectedRange: NSRange(location: persisted.selectedRangeLocation, length: persisted.selectedRangeLength),
            fileURL: persisted.filePath.map(URL.init(fileURLWithPath:)),
            syncMetadata: persisted.syncMetadata
        )
    }
}
