import AppKit
import Foundation

private enum DirectoryNoteMetadataKey {
    static let storageExtension = "storageExtension"
    static let textEncoding = "textEncoding"
    static let fileModificationTimeInterval = "fileModificationTimeInterval"
    static let fileSize = "fileSize"
}

enum TextEncodingRepairOption: String, CaseIterable, Identifiable {
    case utf8
    case isoLatin1
    case windowsCP1252
    case macOSRoman
    case utf16

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .utf8:
            "Unicode (UTF-8)"
        case .isoLatin1:
            "Western (ISO Latin 1)"
        case .windowsCP1252:
            "Western (Windows Latin 1)"
        case .macOSRoman:
            "Western (Mac Roman)"
        case .utf16:
            "Unicode (UTF-16)"
        }
    }

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8:
            .utf8
        case .isoLatin1:
            .isoLatin1
        case .windowsCP1252:
            .windowsCP1252
        case .macOSRoman:
            .macOSRoman
        case .utf16:
            .utf16
        }
    }
}

protocol LegacyStorageAdapter {
    var backend: StorageBackendKind { get }
    func canReadLegacyStore() -> Bool
    func canWriteLegacyStore() -> Bool
    func suggestedNotesDirectoryPath() -> String
    func supportsDirectorySync() -> Bool
    func supportsJournaling() -> Bool
    func supportedFormats() -> [String]
}

struct RewriteJSONStorageAdapter: LegacyStorageAdapter {
    let backend: StorageBackendKind = .rewriteJSON

    func canReadLegacyStore() -> Bool { false }
    func canWriteLegacyStore() -> Bool { false }
    func suggestedNotesDirectoryPath() -> String { "" }
    func supportsDirectorySync() -> Bool { false }
    func supportsJournaling() -> Bool { false }
    func supportedFormats() -> [String] { ["Rewrite JSON"] }
}

struct LegacySingleDatabaseStorageAdapter: LegacyStorageAdapter {
    static let databaseFileName = "Notes & Settings"
    static let backupFileName = "Notes & Settings.backup"
    static let journalFileName = "Interim Note-Changes"

    let backend: StorageBackendKind = .legacySingleDatabase

    func canReadLegacyStore() -> Bool { true }
    func canWriteLegacyStore() -> Bool { true }
    func suggestedNotesDirectoryPath() -> String { "" }
    func supportsDirectorySync() -> Bool { false }
    func supportsJournaling() -> Bool { true }
    func supportedFormats() -> [String] { ["Legacy Single Database"] }

    func loadNotes(
        from directoryPath: String,
        preferredFontName: String,
        preferredFontSize: CGFloat,
        passphraseData: Data? = nil
    ) -> LegacySingleDatabaseLoadResult {
        guard !directoryPath.isEmpty else { return .missingDatabase }

        let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let databaseURL = directoryURL.appendingPathComponent(Self.databaseFileName)
        let journalURL = directoryURL.appendingPathComponent(Self.journalFileName)
        let backupURL = directoryURL.appendingPathComponent(Self.backupFileName)

        let databaseResult = LegacySingleDatabaseArchiveLoader.loadNotes(
            from: databaseURL,
            preferredFontName: preferredFontName,
            preferredFontSize: preferredFontSize,
            source: .database,
            passphraseData: passphraseData
        )

        if case let .success(notes, _) = databaseResult {
            if FileManager.default.fileExists(atPath: journalURL.path),
               let recoveredNotes = LegacySingleDatabaseArchiveLoader.recoveredJournalState(
                at: journalURL,
                baseNotes: notes,
                baseDeletedNotes: LegacySingleDatabaseArchiveLoader.currentDeletedNoteSet(from: databaseURL) ?? []
               ) {
                return .success(recoveredNotes, source: .journal)
            }
            return databaseResult
        }

        if FileManager.default.fileExists(atPath: journalURL.path) {
            if let recoveredNotes = LegacySingleDatabaseArchiveLoader.recoveredJournalState(at: journalURL) {
                return .success(recoveredNotes, source: .journal)
            }
        }

        if FileManager.default.fileExists(atPath: backupURL.path) {
            let backupResult = LegacySingleDatabaseArchiveLoader.loadNotes(
                from: backupURL,
                preferredFontName: preferredFontName,
                preferredFontSize: preferredFontSize,
                source: .backup,
                passphraseData: passphraseData
            )
            if case .success = backupResult {
                return backupResult
            }
        }
        return databaseResult
    }

    func writeNotes(
        _ notes: [Note],
        to directoryPath: String,
        prefs: LegacyNotationPrefsArchive,
        passphraseData: Data? = nil
    ) -> LegacySingleDatabaseWriteResult {
        guard !directoryPath.isEmpty else {
            return .failure("No database folder is configured for the legacy single-database backend.")
        }
        let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let databaseURL = directoryURL.appendingPathComponent(Self.databaseFileName)
        let backupURL = directoryURL.appendingPathComponent(Self.backupFileName)
        let journalURL = directoryURL.appendingPathComponent(Self.journalFileName)
        let existingFrozenNotation = LegacySingleDatabaseArchiveLoader.loadFrozenNotation(from: databaseURL)
        let preservedDeletedNotes = existingFrozenNotation?.deletedNoteSet

        let fileManager = FileManager.default
        var backupCreated = false
        var journalCreated = false

        let existingNotesResult = loadNotes(
            from: directoryPath,
            preferredFontName: "Menlo",
            preferredFontSize: 14,
            passphraseData: passphraseData
        )
        let existingNotes: [Note]
        switch existingNotesResult {
        case .success(let loadedNotes, _):
            existingNotes = loadedNotes
        default:
            existingNotes = []
        }

        let existingByID = Dictionary(uniqueKeysWithValues: existingNotes.map { ($0.id, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        var persistedNotes: [Note] = []
        var journalDeletedNotes: [LegacyDeletedNoteArchive] = []

        for note in notes {
            if let existingNote = existingByID[note.id],
               !LegacySingleDatabaseArchiveLoader.notesAreEquivalentForArchive(existingNote, note) {
                persistedNotes.append(LegacySingleDatabaseArchiveLoader.noteWithIncrementedLSN(
                    note,
                    from: Int32(existingNote.syncMetadata["legacyLogSequenceNumber"] ?? "0")
                ))
            } else if existingByID[note.id] == nil {
                persistedNotes.append(LegacySingleDatabaseArchiveLoader.noteWithIncrementedLSN(note, from: nil))
            } else {
                persistedNotes.append(note)
            }
        }

        for existingNote in existingNotes where currentByID[existingNote.id] == nil {
            journalDeletedNotes.append(
                LegacySingleDatabaseArchiveLoader.deletedRecord(
                    for: existingNote,
                    previousLSN: Int32(existingNote.syncMetadata["legacyLogSequenceNumber"] ?? "0")
                )
            )
        }

        let changedNotes = persistedNotes.filter { note in
            guard let existingNote = existingByID[note.id] else { return true }
            return !LegacySingleDatabaseArchiveLoader.notesAreEquivalentForArchive(existingNote, note) ||
                existingNote.syncMetadata["legacyLogSequenceNumber"] != note.syncMetadata["legacyLogSequenceNumber"]
        }

        var mergedDeletedNotes: [LegacyDeletedNoteArchive] = (preservedDeletedNotes?.allObjects as? [LegacyDeletedNoteArchive]) ?? []
        let changedNoteIDs = Set(changedNotes.map(\.id))
        mergedDeletedNotes.removeAll { deleted in
            deleted.uniqueNoteIDBytes.flatMap(UUID.init(data:)).map { changedNoteIDs.contains($0) } ?? false
        }
        mergedDeletedNotes.removeAll { deleted in
            deleted.uniqueNoteIDBytes.flatMap(UUID.init(data:)).map { currentByID[$0] != nil } ?? false
        }
        for deleted in journalDeletedNotes {
            guard let deletedID = deleted.uniqueNoteIDBytes.flatMap(UUID.init(data:)) else { continue }
            mergedDeletedNotes.removeAll { existing in
                existing.uniqueNoteIDBytes.flatMap(UUID.init(data:)) == deletedID
            }
            mergedDeletedNotes.append(deleted)
        }

        guard let archiveData = LegacySingleDatabaseArchiveLoader.archivedData(
            for: persistedNotes,
            prefs: prefs,
            passphraseData: passphraseData,
            preservedDeletedNotes: NSSet(array: mergedDeletedNotes)
        ) else {
            return .failure("The rewrite could not serialize the legacy single-database archive.")
        }

        if !changedNotes.isEmpty || !journalDeletedNotes.isEmpty {
            guard let journalData = LegacySingleDatabaseArchiveLoader.journalData(
                for: changedNotes,
                removedNotes: journalDeletedNotes
            ) else {
                return .failure("The pending journal entries could not be serialized before saving Notes & Settings.")
            }
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                if !fileManager.fileExists(atPath: journalURL.path) {
                    fileManager.createFile(atPath: journalURL.path, contents: nil)
                }
                if let handle = try? FileHandle(forWritingTo: journalURL) {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: journalData)
                    try handle.synchronize()
                    try handle.close()
                    journalCreated = true
                } else {
                    return .failure("The pending journal file could not be opened for append before saving Notes & Settings.")
                }
            } catch {
                return .failure("The pending journal file could not be written before saving Notes & Settings.")
            }
        }

        if fileManager.fileExists(atPath: databaseURL.path) {
            try? fileManager.removeItem(at: backupURL)
            do {
                try fileManager.copyItem(at: databaseURL, to: backupURL)
                backupCreated = true
            } catch {
                return .failure("The existing database could not be snapshotted before writing.")
            }
        }

        do {
            try archiveData.write(to: databaseURL, options: .atomic)
        } catch {
            return .failure("The rewrite could not write the unencrypted Notes & Settings archive.")
        }

        let verificationResult = LegacySingleDatabaseArchiveLoader.loadNotes(
            from: databaseURL,
            preferredFontName: "Menlo",
            preferredFontSize: 14,
            source: .database,
            passphraseData: passphraseData
        )
        guard case .success = verificationResult else {
            return .failure("The legacy archive was written, but immediate verification failed. Use the backup or journal recovery actions.")
        }

        if journalCreated {
            try? fileManager.removeItem(at: journalURL)
        }

        let databaseBackedNotes = persistedNotes.map { note in
            var copy = note
            copy.fileURL = databaseURL
            copy.syncMetadata["storageBackend"] = "legacySingleDatabase"
            return copy
        }
        return .success(databaseBackedNotes, backupCreated: backupCreated, journalCreated: journalCreated)
    }

    func backupExists(at directoryPath: String) -> Bool {
        guard !directoryPath.isEmpty else { return false }
        let backupURL = URL(fileURLWithPath: directoryPath, isDirectory: true).appendingPathComponent(Self.backupFileName)
        return FileManager.default.fileExists(atPath: backupURL.path)
    }

    func journalExists(at directoryPath: String) -> Bool {
        guard !directoryPath.isEmpty else { return false }
        let journalURL = URL(fileURLWithPath: directoryPath, isDirectory: true).appendingPathComponent(Self.journalFileName)
        return FileManager.default.fileExists(atPath: journalURL.path)
    }

    func restoreBackup(at directoryPath: String) -> Bool {
        guard !directoryPath.isEmpty else { return false }
        let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let databaseURL = directoryURL.appendingPathComponent(Self.databaseFileName)
        let backupURL = directoryURL.appendingPathComponent(Self.backupFileName)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: backupURL.path) else { return false }

        do {
            if fileManager.fileExists(atPath: databaseURL.path) {
                try fileManager.removeItem(at: databaseURL)
            }
            try fileManager.copyItem(at: backupURL, to: databaseURL)
            return true
        } catch {
            return false
        }
    }

    func restoreJournal(at directoryPath: String) -> Bool {
        guard !directoryPath.isEmpty else { return false }
        let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let databaseURL = directoryURL.appendingPathComponent(Self.databaseFileName)
        let journalURL = directoryURL.appendingPathComponent(Self.journalFileName)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: journalURL.path) else { return false }

        do {
            if fileManager.fileExists(atPath: databaseURL.path) {
                try fileManager.removeItem(at: databaseURL)
            }
            try fileManager.copyItem(at: journalURL, to: databaseURL)
            return true
        } catch {
            return false
        }
    }

    func commitRecoveredDatabase(at directoryPath: String, source: LegacyRecoverySource) -> Bool {
        guard !directoryPath.isEmpty else { return false }
        let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let databaseURL = directoryURL.appendingPathComponent(Self.databaseFileName)
        let backupURL = directoryURL.appendingPathComponent(Self.backupFileName)
        let journalURL = directoryURL.appendingPathComponent(Self.journalFileName)
        let fileManager = FileManager.default

        let sourceURL: URL
        switch source {
        case .database:
            sourceURL = databaseURL
        case .journal:
            sourceURL = journalURL
        case .backup:
            sourceURL = backupURL
        }

        guard fileManager.fileExists(atPath: sourceURL.path) else { return false }

        let commitBackupURL = directoryURL.appendingPathComponent("Notes & Settings.pre-commit-backup")
        try? fileManager.removeItem(at: commitBackupURL)
        if fileManager.fileExists(atPath: databaseURL.path), source != .database {
            try? fileManager.copyItem(at: databaseURL, to: commitBackupURL)
        }

        do {
            if source != .database {
                if fileManager.fileExists(atPath: databaseURL.path) {
                    try fileManager.removeItem(at: databaseURL)
                }
                try fileManager.copyItem(at: sourceURL, to: databaseURL)
            }

            if source == .journal, fileManager.fileExists(atPath: journalURL.path) {
                try fileManager.removeItem(at: journalURL)
            }
            return true
        } catch {
            return false
        }
    }
}

enum LegacySingleDatabaseWriteResult {
    case success([Note], backupCreated: Bool, journalCreated: Bool)
    case failure(String)
}

struct LegacyDirectoryStorageAdapter: LegacyStorageAdapter {
    let backend: StorageBackendKind = .legacyFileDirectory

    func canReadLegacyStore() -> Bool { true }
    func canWriteLegacyStore() -> Bool { true }
    func suggestedNotesDirectoryPath() -> String { "" }
    func supportsDirectorySync() -> Bool { true }
    func supportsJournaling() -> Bool { false }
    func supportedFormats() -> [String] { ["txt", "text", "md", "markdown", "rtf", "html", "htm"] }

    func loadNotes(from directoryPath: String) -> [Note] {
        guard !directoryPath.isEmpty else { return [] }
        let fileManager = FileManager.default
        let directoryURL = URL(fileURLWithPath: directoryPath)

        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var loaded: [Note] = []

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }

            let ext = fileURL.pathExtension.lowercased()
            guard supportedFormats().contains(ext) else { continue }

            if let note = note(from: fileURL, resourceValues: values) {
                loaded.append(note)
            }
        }

        return loaded.sorted { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.modifiedAt > rhs.modifiedAt
        }
    }

    func loadNotes(from fileURLs: [URL]) -> [Note] {
        fileURLs.compactMap { fileURL in
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                return nil
            }
            return note(from: fileURL, resourceValues: values)
        }
        .sorted { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.modifiedAt > rhs.modifiedAt
        }
    }

    func supportsEncodingRepair(for note: Note) -> Bool {
        let ext = note.fileURL?.pathExtension.lowercased()
            ?? note.syncMetadata[DirectoryNoteMetadataKey.storageExtension]?.lowercased()
            ?? ""
        guard !ext.isEmpty else { return false }
        return !["rtf", "html", "htm"].contains(ext)
    }

    func reloadNote(_ existingNote: Note, withEncoding encodingOption: TextEncodingRepairOption) -> Note? {
        guard let fileURL = existingNote.fileURL,
              let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey]),
              values.isRegularFile == true,
              supportsEncodingRepair(for: existingNote),
              let reloaded = note(from: fileURL, resourceValues: values, forcedTextEncoding: encodingOption.stringEncoding) else {
            return nil
        }

        return Note(
            id: existingNote.id,
            title: reloaded.title,
            body: reloaded.body,
            labels: existingNote.labels,
            createdAt: reloaded.createdAt,
            modifiedAt: reloaded.modifiedAt,
            selectedRange: existingNote.selectedRange,
            fileURL: reloaded.fileURL,
            syncMetadata: existingNote.syncMetadata.merging(reloaded.syncMetadata) { _, repaired in repaired }
        )
    }

    func writeNote(_ note: Note, to directoryPath: String) throws -> Note {
        let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let preferredExtension = storageExtension(for: note)
        let targetURL: URL
        if let existingURL = note.fileURL {
            let desiredFilename = uniqueFilename(
                for: note.title,
                preferredExtension: existingURL.pathExtension.isEmpty ? preferredExtension : existingURL.pathExtension
            )
            let desiredURL = directoryURL.appendingPathComponent(desiredFilename)
            if existingURL.standardizedFileURL != desiredURL.standardizedFileURL,
               FileManager.default.fileExists(atPath: existingURL.path) {
                try? FileManager.default.removeItem(at: desiredURL)
                try FileManager.default.moveItem(at: existingURL, to: desiredURL)
            }
            targetURL = desiredURL
        } else {
            targetURL = nextAvailableURL(in: directoryURL, title: note.title, ext: preferredExtension)
        }

        let fileData = try serializedData(for: note, pathExtension: targetURL.pathExtension.lowercased())
        try fileData.write(to: targetURL, options: .atomic)

        var updated = note
        updated.fileURL = targetURL
        updated.modifiedAt = Date()
        updated.syncMetadata[DirectoryNoteMetadataKey.storageExtension] = targetURL.pathExtension.lowercased()
        applyCurrentFileMetadata(to: &updated, fileURL: targetURL)
        return updated
    }

    func removeNote(_ note: Note) {
        guard let fileURL = note.fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func uniqueFilename(for title: String, preferredExtension: String) -> String {
        let base = sanitizedBaseName(from: title)
        return "\(base).\(preferredExtension)"
    }

    private func note(
        from fileURL: URL,
        resourceValues values: URLResourceValues,
        forcedTextEncoding: String.Encoding? = nil
    ) -> Note? {
        let ext = fileURL.pathExtension.lowercased()
        guard supportedFormats().contains(ext) else { return nil }

        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Menlo", size: 14) ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]

        let body: NSAttributedString
        var syncMetadata: [String: String] = [
            DirectoryNoteMetadataKey.storageExtension: ext
        ]
        if ["rtf"].contains(ext),
           let attributed = try? NSAttributedString(url: fileURL, options: [:], documentAttributes: nil) {
            body = attributed
        } else if ["html", "htm"].contains(ext),
                  let data = try? Data(contentsOf: fileURL),
                  let attributed = try? NSAttributedString(
                    data: data,
                    options: [.documentType: NSAttributedString.DocumentType.html],
                    documentAttributes: nil
                  ) {
            body = attributed
        } else if let encoding = forcedTextEncoding,
                  let data = try? Data(contentsOf: fileURL),
                  let string = String(data: data, encoding: encoding) {
            body = NSAttributedString(string: string, attributes: bodyAttributes)
            syncMetadata[DirectoryNoteMetadataKey.textEncoding] = String(encoding.rawValue)
        } else if let string = try? String(contentsOf: fileURL, encoding: .utf8) {
            body = NSAttributedString(string: string, attributes: bodyAttributes)
            syncMetadata[DirectoryNoteMetadataKey.textEncoding] = String(String.Encoding.utf8.rawValue)
        } else if let data = try? Data(contentsOf: fileURL),
                  let string = String(data: data, encoding: .isoLatin1) {
            body = NSAttributedString(string: string, attributes: bodyAttributes)
            syncMetadata[DirectoryNoteMetadataKey.textEncoding] = String(String.Encoding.isoLatin1.rawValue)
        } else {
            return nil
        }

        let title = fileURL.deletingPathExtension().lastPathComponent
        return Note(
            title: title.isEmpty ? "Untitled Note" : title,
            body: body,
            labels: [],
            createdAt: values.creationDate ?? .now,
            modifiedAt: values.contentModificationDate ?? .now,
            selectedRange: NSRange(location: 0, length: 0),
            fileURL: fileURL,
            syncMetadata: enrichedMetadata(syncMetadata, with: values)
        )
    }

    private func storageExtension(for note: Note) -> String {
        if let existingExtension = note.fileURL?.pathExtension, !existingExtension.isEmpty {
            return existingExtension.lowercased()
        }

        if let storedExtension = note.syncMetadata[DirectoryNoteMetadataKey.storageExtension], !storedExtension.isEmpty {
            return storedExtension.lowercased()
        }

        return "txt"
    }

    private func serializedData(for note: Note, pathExtension: String) throws -> Data {
        switch pathExtension {
        case "rtf":
            return try note.body.data(
                from: NSRange(location: 0, length: note.body.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
        case "html", "htm":
            return try note.body.data(
                from: NSRange(location: 0, length: note.body.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
            )
        default:
            let encoding = textEncoding(for: note)
            return note.plainBody.data(using: encoding) ?? note.plainBody.data(using: .utf8) ?? Data()
        }
    }

    private func textEncoding(for note: Note) -> String.Encoding {
        guard let rawValue = note.syncMetadata[DirectoryNoteMetadataKey.textEncoding],
              let numericValue = UInt(rawValue) else {
            return .utf8
        }
        return String.Encoding(rawValue: numericValue)
    }

    private func nextAvailableURL(in directoryURL: URL, title: String, ext: String) -> URL {
        let base = sanitizedBaseName(from: title)
        var candidate = directoryURL.appendingPathComponent("\(base).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directoryURL.appendingPathComponent("\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    private func sanitizedBaseName(from title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "Untitled Note" : trimmed
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = fallback.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "Untitled Note" : cleaned
    }

    func hasExternalConflict(for note: Note, at fileURL: URL) -> Bool {
        guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return false
        }

        let storedTimeInterval = note.syncMetadata[DirectoryNoteMetadataKey.fileModificationTimeInterval].flatMap(TimeInterval.init)
        let storedFileSize = note.syncMetadata[DirectoryNoteMetadataKey.fileSize].flatMap(Int.init)
        let currentTimeInterval = values.contentModificationDate?.timeIntervalSinceReferenceDate
        let currentFileSize = values.fileSize

        if let storedTimeInterval, let currentTimeInterval,
           abs(storedTimeInterval - currentTimeInterval) > 0.001 {
            return true
        }

        if let storedFileSize, let currentFileSize, storedFileSize != currentFileSize {
            return true
        }

        return false
    }

    private func applyCurrentFileMetadata(to note: inout Note, fileURL: URL) {
        guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        if let contentModificationDate = values.contentModificationDate {
            note.syncMetadata[DirectoryNoteMetadataKey.fileModificationTimeInterval] = String(contentModificationDate.timeIntervalSinceReferenceDate)
        }
        if let fileSize = values.fileSize {
            note.syncMetadata[DirectoryNoteMetadataKey.fileSize] = String(fileSize)
        }
    }

    private func enrichedMetadata(_ metadata: [String: String], with values: URLResourceValues) -> [String: String] {
        var enriched = metadata
        if let contentModificationDate = values.contentModificationDate {
            enriched[DirectoryNoteMetadataKey.fileModificationTimeInterval] = String(contentModificationDate.timeIntervalSinceReferenceDate)
        }
        if let fileSize = values.fileSize {
            enriched[DirectoryNoteMetadataKey.fileSize] = String(fileSize)
        }
        return enriched
    }
}

func makeLegacyStorageAdapter(for backend: StorageBackendKind) -> LegacyStorageAdapter {
    switch backend {
    case .rewriteJSON:
        RewriteJSONStorageAdapter()
    case .legacySingleDatabase:
        LegacySingleDatabaseStorageAdapter()
    case .legacyFileDirectory:
        LegacyDirectoryStorageAdapter()
    }
}
