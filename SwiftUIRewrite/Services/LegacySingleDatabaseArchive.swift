import AppKit
import CommonCrypto
import Compression
import Foundation

private enum LegacyArchiveMetadataKey {
    static let logSequenceNumber = "legacyLogSequenceNumber"
}

@objc(FrozenNotation)
final class LegacyFrozenNotationArchive: NSObject, NSCoding {
    let prefs: LegacyNotationPrefsArchive?
    let notesData: Data?
    let deletedNoteSet: NSSet?

    init(prefs: LegacyNotationPrefsArchive, notesData: Data, deletedNoteSet: NSSet = []) {
        self.prefs = prefs
        self.notesData = notesData
        self.deletedNoteSet = deletedNoteSet
        super.init()
    }

    init?(coder: NSCoder) {
        if coder.containsValue(forKey: "prefs") {
            prefs = coder.decodeObject(forKey: "prefs") as? LegacyNotationPrefsArchive
            notesData = coder.decodeObject(forKey: "notesData") as? Data
            deletedNoteSet = coder.decodeObject(forKey: "deletedNoteSet") as? NSSet
        } else {
            prefs = coder.decodeObject() as? LegacyNotationPrefsArchive
            notesData = coder.decodeObject() as? Data
            _ = coder.decodeObject()
            deletedNoteSet = nil
        }
        super.init()
    }

    func encode(with coder: NSCoder) {
        if coder.allowsKeyedCoding {
            coder.encode(prefs, forKey: "prefs")
            coder.encode(notesData, forKey: "notesData")
            coder.encode(deletedNoteSet, forKey: "deletedNoteSet")
        } else {
            coder.encode(prefs)
            coder.encode(notesData)
            coder.encode(deletedNoteSet)
        }
    }
}

@objc(NotationPrefs)
final class LegacyNotationPrefsArchive: NSObject, NSCoding {
    let doesEncryption: Bool
    let storesPasswordInKeychain: Bool
    let secureTextEntry: Bool
    let hashIterationCount: Int
    let keyLengthInBits: Int
    let keychainDatabaseIdentifier: String?
    let masterSalt: Data?
    let dataSessionSalt: Data?
    let verifierKey: Data?
    let epochIteration: Int32

    init(
        doesEncryption: Bool,
        storesPasswordInKeychain: Bool = false,
        secureTextEntry: Bool = false,
        hashIterationCount: Int = LegacyEncryptionSupport.defaultHashIterations,
        keyLengthInBits: Int = LegacyEncryptionSupport.defaultKeyLengthInBits,
        keychainDatabaseIdentifier: String? = nil,
        masterSalt: Data? = nil,
        dataSessionSalt: Data? = nil,
        verifierKey: Data? = nil,
        epochIteration: Int32 = 4
    ) {
        self.doesEncryption = doesEncryption
        self.storesPasswordInKeychain = storesPasswordInKeychain
        self.secureTextEntry = secureTextEntry
        self.hashIterationCount = hashIterationCount
        self.keyLengthInBits = keyLengthInBits
        self.keychainDatabaseIdentifier = keychainDatabaseIdentifier
        self.masterSalt = masterSalt
        self.dataSessionSalt = dataSessionSalt
        self.verifierKey = verifierKey
        self.epochIteration = epochIteration
        super.init()
    }

    init?(coder: NSCoder) {
        if coder.allowsKeyedCoding {
            doesEncryption = coder.decodeBool(forKey: "doesEncryption")
            storesPasswordInKeychain = coder.decodeBool(forKey: "storesPasswordInKeychain")
            secureTextEntry = coder.decodeBool(forKey: "secureTextEntry")
            let decodedHashIterations = coder.decodeInteger(forKey: "hashIterationCount")
            hashIterationCount = decodedHashIterations == 0 ? LegacyEncryptionSupport.defaultHashIterations : decodedHashIterations
            let decodedKeyLength = coder.decodeInteger(forKey: "keyLengthInBits")
            keyLengthInBits = decodedKeyLength == 0 ? LegacyEncryptionSupport.defaultKeyLengthInBits : decodedKeyLength
            keychainDatabaseIdentifier = coder.decodeObject(forKey: "keychainDatabaseIdentifier") as? String
            masterSalt = coder.decodeObject(forKey: "masterSalt") as? Data
            dataSessionSalt = coder.decodeObject(forKey: "dataSessionSalt") as? Data
            verifierKey = coder.decodeObject(forKey: "verifierKey") as? Data
            epochIteration = coder.decodeInt32(forKey: "epochIteration")
        } else {
            doesEncryption = false
            storesPasswordInKeychain = false
            secureTextEntry = false
            hashIterationCount = LegacyEncryptionSupport.defaultHashIterations
            keyLengthInBits = LegacyEncryptionSupport.defaultKeyLengthInBits
            keychainDatabaseIdentifier = nil
            masterSalt = nil
            dataSessionSalt = nil
            verifierKey = nil
            epochIteration = 0
        }
        super.init()
    }

    func encode(with coder: NSCoder) {
        if coder.allowsKeyedCoding {
            coder.encode(doesEncryption, forKey: "doesEncryption")
            coder.encode(storesPasswordInKeychain, forKey: "storesPasswordInKeychain")
            coder.encode(secureTextEntry, forKey: "secureTextEntry")
            coder.encode(hashIterationCount, forKey: "hashIterationCount")
            coder.encode(keyLengthInBits, forKey: "keyLengthInBits")
            coder.encode(keychainDatabaseIdentifier, forKey: "keychainDatabaseIdentifier")
            coder.encode(masterSalt, forKey: "masterSalt")
            coder.encode(dataSessionSalt, forKey: "dataSessionSalt")
            coder.encode(verifierKey, forKey: "verifierKey")
            coder.encode(epochIteration, forKey: "epochIteration")
        }
    }
}

@objc(DeletedNoteObject)
final class LegacyDeletedNoteArchive: NSObject, NSCoding {
    let uniqueNoteIDBytes: Data?
    let syncServicesMD: NSDictionary?
    let logSequenceNumber: Int32

    init(uniqueNoteIDBytes: Data?, syncServicesMD: NSDictionary?, logSequenceNumber: Int32) {
        self.uniqueNoteIDBytes = uniqueNoteIDBytes
        self.syncServicesMD = syncServicesMD
        self.logSequenceNumber = logSequenceNumber
        super.init()
    }

    init?(coder: NSCoder) {
        if coder.allowsKeyedCoding {
            var decodedLength = 0
            if let decodedUUIDBytes = coder.decodeBytes(forKey: "uniqueNoteIDBytes", returnedLength: &decodedLength) {
                uniqueNoteIDBytes = Data(bytes: decodedUUIDBytes, count: decodedLength)
            } else {
                uniqueNoteIDBytes = nil
            }
            syncServicesMD = coder.decodeObject(forKey: "syncServicesMD") as? NSDictionary
            logSequenceNumber = coder.decodeInt32(forKey: "logSequenceNumber")
        } else {
            uniqueNoteIDBytes = nil
            syncServicesMD = nil
            logSequenceNumber = 0
        }
        super.init()
    }

    func encode(with coder: NSCoder) {
        if coder.allowsKeyedCoding {
            if let uniqueNoteIDBytes {
                uniqueNoteIDBytes.withUnsafeBytes { rawBuffer in
                    if let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress {
                        coder.encodeBytes(baseAddress, length: uniqueNoteIDBytes.count, forKey: "uniqueNoteIDBytes")
                    }
                }
            }
            coder.encode(syncServicesMD, forKey: "syncServicesMD")
            coder.encode(logSequenceNumber, forKey: "logSequenceNumber")
        }
    }
}

@objc(NoteObject)
final class LegacyArchivedNoteObject: NSObject, NSCoding {
    let titleString: String?
    let labelString: String?
    let contentString: NSAttributedString?
    let modifiedDate: Double
    let createdDate: Double
    let selectionRange: NSRange
    let uniqueNoteIDBytes: Data?
    let syncServicesMD: NSDictionary?
    let logSequenceNumber: Int32

    init(note: Note) {
        titleString = note.title
        labelString = note.labelsText
        contentString = note.body
        modifiedDate = note.modifiedAt.timeIntervalSinceReferenceDate
        createdDate = note.createdAt.timeIntervalSinceReferenceDate
        selectionRange = note.selectedRange
        uniqueNoteIDBytes = note.id.uuidData
        syncServicesMD = nil
        logSequenceNumber = Int32(note.syncMetadata[LegacyArchiveMetadataKey.logSequenceNumber] ?? "0") ?? 0
        super.init()
    }

    init?(coder: NSCoder) {
        if coder.allowsKeyedCoding {
            modifiedDate = coder.decodeDouble(forKey: "modifiedDate")
            createdDate = coder.decodeDouble(forKey: "createdDate")
            selectionRange = NSRange(
                location: Int(coder.decodeInt32(forKey: "selectionRangeLocation")),
                length: Int(coder.decodeInt32(forKey: "selectionRangeLength"))
            )
            titleString = coder.decodeObject(forKey: "titleString") as? String
            labelString = coder.decodeObject(forKey: "labelString") as? String
            contentString = coder.decodeObject(forKey: "contentString") as? NSAttributedString
            syncServicesMD = coder.decodeObject(forKey: "syncServicesMD") as? NSDictionary
            logSequenceNumber = coder.decodeInt32(forKey: "logSequenceNumber")
            var decodedLength = 0
            if let decodedUUIDBytes = coder.decodeBytes(forKey: "uniqueNoteIDBytes", returnedLength: &decodedLength) {
                uniqueNoteIDBytes = Data(bytes: decodedUUIDBytes, count: decodedLength)
            } else {
                uniqueNoteIDBytes = nil
            }
        } else {
            modifiedDate = 0
            createdDate = 0
            selectionRange = NSRange(location: 0, length: 0)
            titleString = coder.decodeObject() as? String
            labelString = coder.decodeObject() as? String
            contentString = coder.decodeObject() as? NSAttributedString
            syncServicesMD = nil
            logSequenceNumber = 0
            _ = coder.decodeObject()
            uniqueNoteIDBytes = nil
        }
        super.init()
    }

    func encode(with coder: NSCoder) {
        if coder.allowsKeyedCoding {
            coder.encode(modifiedDate, forKey: "modifiedDate")
            coder.encode(createdDate, forKey: "createdDate")
            coder.encode(Int32(selectionRange.location), forKey: "selectionRangeLocation")
            coder.encode(Int32(selectionRange.length), forKey: "selectionRangeLength")
            coder.encode(titleString, forKey: "titleString")
            coder.encode(labelString, forKey: "labelString")
            coder.encode(contentString, forKey: "contentString")
            coder.encode(syncServicesMD, forKey: "syncServicesMD")
            coder.encode(logSequenceNumber, forKey: "logSequenceNumber")
            if let uniqueNoteIDBytes {
                uniqueNoteIDBytes.withUnsafeBytes { rawBuffer in
                    if let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress {
                        coder.encodeBytes(baseAddress, length: uniqueNoteIDBytes.count, forKey: "uniqueNoteIDBytes")
                    }
                }
            }
        }
    }
}

enum LegacySingleDatabaseLoadResult {
    case success([Note], source: LegacySingleDatabaseLoadSource)
    case missingDatabase
    case unreadableArchive
    case encryptedArchive
    case incorrectPassphrase
    case decompressionFailed
    case noteDecodingFailed
}

enum LegacySingleDatabaseLoadSource {
    case database
    case journal
    case backup
}

private enum LegacyWALRecordObject {
    case note(LegacyArchivedNoteObject)
    case deleted(LegacyDeletedNoteArchive)
}

private struct LegacyWALRecoveryState {
    var notes: [Note]
    var deletedNoteSet: NSSet
}

private struct LegacyWALRecordHeader {
    static let saltLength = 32
    static let encodedLength = (MemoryLayout<UInt32>.size * 3) + saltLength

    var originalDataLength: UInt32
    var dataLength: UInt32
    var checksum: UInt32
    var salt: Data
}

enum LegacySingleDatabaseArchiveLoader {
    static func loadFrozenNotation(from databaseURL: URL) -> LegacyFrozenNotationArchive? {
        guard FileManager.default.fileExists(atPath: databaseURL.path),
              let archiveData = try? Data(contentsOf: databaseURL) else {
            return nil
        }
        return decodeFrozenNotation(from: archiveData)
    }

    static func loadNotes(
        from databaseURL: URL,
        preferredFontName: String,
        preferredFontSize: CGFloat,
        source: LegacySingleDatabaseLoadSource = .database,
        passphraseData: Data? = nil
    ) -> LegacySingleDatabaseLoadResult {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return .missingDatabase
        }
        guard let archiveData = try? Data(contentsOf: databaseURL) else {
            return .unreadableArchive
        }
        guard let frozenNotation = decodeFrozenNotation(from: archiveData) else {
            return .unreadableArchive
        }
        guard let prefs = frozenNotation.prefs else {
            return .unreadableArchive
        }

        guard let baseState = decodedArchiveState(
            frozenNotation: frozenNotation,
            databaseURL: databaseURL,
            preferredFontName: preferredFontName,
            preferredFontSize: preferredFontSize,
            passphraseData: passphraseData
        ) else {
            if prefs.doesEncryption, passphraseData == nil {
                return .encryptedArchive
            }
            if prefs.doesEncryption, passphraseData != nil,
               LegacyEncryptionSupport.verify(passphraseData: passphraseData!, prefs: prefs) == nil {
                return .incorrectPassphrase
            }
            return .noteDecodingFailed
        }

        return .success(baseState.notes, source: source)
    }

    static func recoveredJournalState(
        at journalURL: URL,
        baseNotes: [Note] = [],
        baseDeletedNotes: NSSet = []
    ) -> [Note]? {
        recoverJournal(at: journalURL, baseNotes: baseNotes, baseDeletedNotes: baseDeletedNotes)?.notes
    }

    static func currentDeletedNoteSet(from databaseURL: URL) -> NSSet? {
        loadFrozenNotation(from: databaseURL)?.deletedNoteSet
    }

    static func journalData(
        for notes: [Note],
        removedNotes: [LegacyDeletedNoteArchive],
        sessionKey: Data = legacyWALSessionKey()
    ) -> Data? {
        var result = Data()
        for note in notes {
            let object = LegacyArchivedNoteObject(note: note)
            guard let record = journalRecordData(for: object, sessionKey: sessionKey) else { return nil }
            result.append(record)
        }
        for removedNote in removedNotes {
            guard let record = journalRecordData(for: removedNote, sessionKey: sessionKey) else { return nil }
            result.append(record)
        }
        return result
    }

    static func noteWithIncrementedLSN(_ note: Note, from previousLSN: Int32?) -> Note {
        var updated = note
        let nextLSN = max(previousLSN ?? 0, Int32(note.syncMetadata[LegacyArchiveMetadataKey.logSequenceNumber] ?? "0") ?? 0) + 1
        updated.syncMetadata[LegacyArchiveMetadataKey.logSequenceNumber] = String(nextLSN)
        return updated
    }

    static func deletedRecord(for note: Note, previousLSN: Int32?) -> LegacyDeletedNoteArchive {
        let nextLSN = max(previousLSN ?? 0, Int32(note.syncMetadata[LegacyArchiveMetadataKey.logSequenceNumber] ?? "0") ?? 0) + 1
        return LegacyDeletedNoteArchive(
            uniqueNoteIDBytes: note.id.uuidData,
            syncServicesMD: nil,
            logSequenceNumber: nextLSN
        )
    }

    static func notesAreEquivalentForArchive(_ lhs: Note, _ rhs: Note) -> Bool {
        lhs.id == rhs.id &&
        lhs.title == rhs.title &&
        lhs.labels == rhs.labels &&
        lhs.selectedRange == rhs.selectedRange &&
        lhs.createdAt == rhs.createdAt &&
        lhs.body.isEqual(to: rhs.body)
    }

    private static func decodedArchiveState(
        frozenNotation: LegacyFrozenNotationArchive,
        databaseURL: URL,
        preferredFontName: String,
        preferredFontSize: CGFloat,
        passphraseData: Data?
    ) -> LegacyWALRecoveryState? {
        guard let prefs = frozenNotation.prefs else { return nil }
        var compressedNotesData = frozenNotation.notesData
        if prefs.doesEncryption {
            guard let passphraseData,
                  let masterKey = LegacyEncryptionSupport.verify(passphraseData: passphraseData, prefs: prefs),
                  let encryptedNotesData = frozenNotation.notesData,
                  let decryptedNotesData = LegacyEncryptionSupport.decrypt(encryptedNotesData, masterKey: masterKey, prefs: prefs) else {
                return nil
            }
            compressedNotesData = decryptedNotesData
        }
        guard let compressedNotesData,
              let notesData = decompressNVZlibData(compressedNotesData),
              let archivedNotes = decodeNotes(from: notesData) else {
            return nil
        }

        let fallbackAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: preferredFontName, size: preferredFontSize)
                ?? NSFont.monospacedSystemFont(ofSize: preferredFontSize, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]

        let notes: [Note] = archivedNotes.compactMap { archivedNote in
            let title = archivedNote.titleString?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let title, !title.isEmpty else { return nil }

            let body = archivedNote.contentString ?? NSAttributedString(string: "", attributes: fallbackAttributes)
            let labels = archivedNote.labelString?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? []

            var note = Note(
                id: archivedNote.uniqueNoteIDBytes.flatMap(UUID.init(data:)) ?? UUID(),
                title: title,
                body: body,
                labels: labels,
                createdAt: Date(timeIntervalSinceReferenceDate: archivedNote.createdDate),
                modifiedAt: Date(timeIntervalSinceReferenceDate: archivedNote.modifiedDate),
                selectedRange: archivedNote.selectionRange,
                fileURL: databaseURL,
                syncMetadata: ["storageBackend": "legacySingleDatabase"]
            )
            note.syncMetadata[LegacyArchiveMetadataKey.logSequenceNumber] = String(archivedNote.logSequenceNumber)
            return note
        }
        .sorted { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.modifiedAt > rhs.modifiedAt
        }

        return LegacyWALRecoveryState(notes: notes, deletedNoteSet: frozenNotation.deletedNoteSet ?? [])
    }

    private static func decodeFrozenNotation(from data: Data) -> LegacyFrozenNotationArchive? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
            return nil
        }
        unarchiver.requiresSecureCoding = false
        unarchiver.setClass(LegacyFrozenNotationArchive.self, forClassName: "FrozenNotation")
        unarchiver.setClass(LegacyNotationPrefsArchive.self, forClassName: "NotationPrefs")
        unarchiver.setClass(LegacyDeletedNoteArchive.self, forClassName: "DeletedNoteObject")
        let object = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? LegacyFrozenNotationArchive
        unarchiver.finishDecoding()
        return object
    }

    private static func decodeNotes(from data: Data) -> [LegacyArchivedNoteObject]? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
            return nil
        }
        unarchiver.requiresSecureCoding = false
        unarchiver.setClass(LegacyArchivedNoteObject.self, forClassName: "NoteObject")
        let notes = unarchiver.decodeObject(forKey: "notes") as? [LegacyArchivedNoteObject]
        unarchiver.finishDecoding()
        return notes
    }

    static func saveNotes(
        _ notes: [Note],
        to databaseURL: URL,
        prefs: LegacyNotationPrefsArchive,
        passphraseData: Data? = nil,
        preservedDeletedNotes: NSSet? = nil
    ) -> Bool {
        guard let archiveData = archivedData(for: notes, prefs: prefs, passphraseData: passphraseData, preservedDeletedNotes: preservedDeletedNotes) else {
            return false
        }

        do {
            try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try archiveData.write(to: databaseURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func archivedData(
        for notes: [Note],
        prefs: LegacyNotationPrefsArchive,
        passphraseData: Data? = nil,
        preservedDeletedNotes: NSSet? = nil
    ) -> Data? {
        let archivedNotes = notes.map(LegacyArchivedNoteObject.init(note:))
        let notesArchiver = NSKeyedArchiver(requiringSecureCoding: false)
        notesArchiver.requiresSecureCoding = false
        notesArchiver.encode(archivedNotes, forKey: "notes")
        notesArchiver.finishEncoding()
        let notesData = notesArchiver.encodedData

        guard let compressedNotesData = compressNVZlibData(notesData) else {
            return nil
        }

        let finalNotesData: Data
        let finalPrefs: LegacyNotationPrefsArchive
        if prefs.doesEncryption {
            guard let passphraseData,
                  let masterKey = LegacyEncryptionSupport.verify(passphraseData: passphraseData, prefs: prefs),
                  let encryptedResult = LegacyEncryptionSupport.encrypt(compressedNotesData, masterKey: masterKey, prefs: prefs) else {
                return nil
            }
            finalNotesData = encryptedResult.ciphertext
            finalPrefs = LegacyNotationPrefsArchive(
                doesEncryption: true,
                storesPasswordInKeychain: prefs.storesPasswordInKeychain,
                secureTextEntry: prefs.secureTextEntry,
                hashIterationCount: prefs.hashIterationCount,
                keyLengthInBits: prefs.keyLengthInBits,
                keychainDatabaseIdentifier: prefs.keychainDatabaseIdentifier,
                masterSalt: prefs.masterSalt,
                dataSessionSalt: encryptedResult.dataSessionSalt,
                verifierKey: prefs.verifierKey,
                epochIteration: prefs.epochIteration
            )
        } else {
            finalNotesData = compressedNotesData
            finalPrefs = prefs
        }

        let frozenNotation = LegacyFrozenNotationArchive(
            prefs: finalPrefs,
            notesData: finalNotesData,
            deletedNoteSet: preservedDeletedNotes ?? []
        )

        return try? NSKeyedArchiver.archivedData(withRootObject: frozenNotation, requiringSecureCoding: false)
    }

    private static func recoverJournal(at journalURL: URL, baseNotes: [Note], baseDeletedNotes: NSSet) -> LegacyWALRecoveryState? {
        guard FileManager.default.fileExists(atPath: journalURL.path),
              let journalData = try? Data(contentsOf: journalURL),
              !journalData.isEmpty else {
            return nil
        }

        var notesByID = Dictionary(uniqueKeysWithValues: baseNotes.map { ($0.id, $0) })
        var deletedByID = Dictionary(uniqueKeysWithValues: (baseDeletedNotes.allObjects as? [LegacyDeletedNoteArchive] ?? []).compactMap { deleted in
            deleted.uniqueNoteIDBytes.flatMap(UUID.init(data:)).map { ($0, deleted) }
        })

        for object in decodeJournalObjects(from: journalData) {
            switch object {
            case .note(let archivedNote):
                guard let note = decodedNote(from: archivedNote, fallbackURL: journalURL.deletingLastPathComponent().appendingPathComponent("Notes & Settings")),
                      let noteLSN = Int32(note.syncMetadata[LegacyArchiveMetadataKey.logSequenceNumber] ?? "0") else {
                    continue
                }
                let existingNoteLSN = notesByID[note.id].flatMap { Int32($0.syncMetadata[LegacyArchiveMetadataKey.logSequenceNumber] ?? "0") } ?? Int32.min
                let deletedLSN = deletedByID[note.id]?.logSequenceNumber ?? Int32.min
                guard noteLSN >= existingNoteLSN, noteLSN >= deletedLSN else { continue }
                notesByID[note.id] = note
                deletedByID.removeValue(forKey: note.id)
            case .deleted(let deleted):
                guard let deletedID = deleted.uniqueNoteIDBytes.flatMap(UUID.init(data:)) else { continue }
                let deletedLSN = deleted.logSequenceNumber
                let existingNoteLSN = notesByID[deletedID].flatMap { Int32($0.syncMetadata[LegacyArchiveMetadataKey.logSequenceNumber] ?? "0") } ?? Int32.min
                let existingDeletedLSN = deletedByID[deletedID]?.logSequenceNumber ?? Int32.min
                guard deletedLSN >= existingNoteLSN, deletedLSN >= existingDeletedLSN else { continue }
                notesByID.removeValue(forKey: deletedID)
                deletedByID[deletedID] = deleted
            }
        }

        let notes = Array(notesByID.values).sorted { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.modifiedAt > rhs.modifiedAt
        }
        return LegacyWALRecoveryState(notes: notes, deletedNoteSet: NSSet(array: Array(deletedByID.values)))
    }

    private static func decodedNote(from archivedNote: LegacyArchivedNoteObject, fallbackURL: URL) -> Note? {
        let title = archivedNote.titleString?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else { return nil }
        let body = archivedNote.contentString ?? NSAttributedString(string: "")
        let labels = archivedNote.labelString?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        var note = Note(
            id: archivedNote.uniqueNoteIDBytes.flatMap(UUID.init(data:)) ?? UUID(),
            title: title,
            body: body,
            labels: labels,
            createdAt: Date(timeIntervalSinceReferenceDate: archivedNote.createdDate),
            modifiedAt: Date(timeIntervalSinceReferenceDate: archivedNote.modifiedDate),
            selectedRange: archivedNote.selectionRange,
            fileURL: fallbackURL,
            syncMetadata: ["storageBackend": "legacySingleDatabase"]
        )
        note.syncMetadata[LegacyArchiveMetadataKey.logSequenceNumber] = String(archivedNote.logSequenceNumber)
        return note
    }

    private static func decodeJournalObjects(from journalData: Data, sessionKey: Data = legacyWALSessionKey()) -> [LegacyWALRecordObject] {
        var offset = 0
        var decoded: [LegacyWALRecordObject] = []

        while offset + LegacyWALRecordHeader.encodedLength <= journalData.count {
            guard let header = parseWALHeader(from: journalData, offset: offset) else { break }
            offset += LegacyWALRecordHeader.encodedLength

            let dataLength = Int(header.dataLength)
            guard offset + dataLength <= journalData.count else { break }
            let encryptedPayload = journalData.subdata(in: offset..<(offset + dataLength))
            offset += dataLength

            guard crc32(encryptedPayload) == header.checksum,
                  let decrypted = decryptWALPayload(encryptedPayload, salt: header.salt, sessionKey: sessionKey),
                  let decompressed = decompressWALRecordPayload(decrypted, expectedSize: Int(header.originalDataLength)),
                  let object = decodeWALObject(from: decompressed) else {
                break
            }

            decoded.append(object)
        }

        return decoded
    }

    private static func journalRecordData(for object: NSObject & NSCoding, sessionKey: Data) -> Data? {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.requiresSecureCoding = false
        archiver.encode(object, forKey: "aNote")
        archiver.finishEncoding()
        let serialized = archiver.encodedData

        guard let compressed = compressWALRecordPayload(serialized),
              let salt = LegacyEncryptionSupport.randomData(length: LegacyWALRecordHeader.saltLength),
              let encrypted = encryptWALPayload(compressed, salt: salt, sessionKey: sessionKey) else {
            return nil
        }

        let header = LegacyWALRecordHeader(
            originalDataLength: UInt32(serialized.count),
            dataLength: UInt32(encrypted.count),
            checksum: crc32(encrypted),
            salt: salt
        )
        var data = Data()
        appendBigEndian(header.originalDataLength, to: &data)
        appendBigEndian(header.dataLength, to: &data)
        appendBigEndian(header.checksum, to: &data)
        data.append(header.salt)
        data.append(encrypted)
        return data
    }

    private static func parseWALHeader(from data: Data, offset: Int) -> LegacyWALRecordHeader? {
        guard offset + LegacyWALRecordHeader.encodedLength <= data.count else { return nil }
        let originalDataLength = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let dataLength = data[(offset + 4)..<(offset + 8)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let checksum = data[(offset + 8)..<(offset + 12)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let salt = data.subdata(in: (offset + 12)..<(offset + 12 + LegacyWALRecordHeader.saltLength))
        return LegacyWALRecordHeader(originalDataLength: originalDataLength, dataLength: dataLength, checksum: checksum, salt: salt)
    }

    private static func appendBigEndian(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func legacyWALSessionKey() -> Data {
        Data("This is a 32 byte temporary key\0".utf8)
    }

    private static func encryptWALPayload(_ data: Data, salt: Data, sessionKey: Data) -> Data? {
        let keyLength = sessionKey.count
        guard let recordKey = LegacyEncryptionSupport.deriveKey(
            passphraseData: sessionKey,
            salt: salt,
            keyLengthInBytes: keyLength,
            iterations: 1
        ) else {
            return nil
        }
        return cryptWALPayload(data, key: recordKey, iv: salt.prefix(16), operation: CCOperation(kCCEncrypt))
    }

    private static func decryptWALPayload(_ data: Data, salt: Data, sessionKey: Data) -> Data? {
        let keyLength = sessionKey.count
        guard let recordKey = LegacyEncryptionSupport.deriveKey(
            passphraseData: sessionKey,
            salt: salt,
            keyLengthInBytes: keyLength,
            iterations: 1
        ) else {
            return nil
        }
        return cryptWALPayload(data, key: recordKey, iv: salt.prefix(16), operation: CCOperation(kCCDecrypt))
    }

    private static func cryptWALPayload(_ data: Data, key: Data, iv: Data, operation: CCOperation) -> Data? {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var outputLength = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress,
                            data.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.count = outputLength
        return output
    }

    private static func compressWALRecordPayload(_ data: Data) -> Data? {
        if data.isEmpty { return nil }
        var destinationCapacity = max(64, Int(Double(data.count) * 1.1) + 16)
        var compressedSize = 0
        var compressed = Data()
        repeat {
            compressed = Data(count: destinationCapacity)
            compressedSize = compressed.withUnsafeMutableBytes { destinationBuffer in
                data.withUnsafeBytes { sourceBuffer in
                    compression_encode_buffer(
                        destinationBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        destinationCapacity,
                        sourceBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        data.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            destinationCapacity *= 2
        } while compressedSize == 0 && destinationCapacity < max(1024 * 1024 * 16, data.count * 8)
        guard compressedSize > 0 else { return nil }
        compressed.count = compressedSize
        return compressed
    }

    private static func decompressWALRecordPayload(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return nil }
        var destination = Data(count: expectedSize)
        let decodedSize = destination.withUnsafeMutableBytes { destinationBuffer in
            data.withUnsafeBytes { sourceBuffer in
                compression_decode_buffer(
                    destinationBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    expectedSize,
                    sourceBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decodedSize == expectedSize else { return nil }
        return destination
    }

    private static func decodeWALObject(from data: Data) -> LegacyWALRecordObject? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        unarchiver.setClass(LegacyArchivedNoteObject.self, forClassName: "NoteObject")
        unarchiver.setClass(LegacyDeletedNoteArchive.self, forClassName: "DeletedNoteObject")
        let object = unarchiver.decodeObject(forKey: "aNote")
        unarchiver.finishDecoding()
        if let note = object as? LegacyArchivedNoteObject {
            return .note(note)
        }
        if let deleted = object as? LegacyDeletedNoteArchive {
            return .deleted(deleted)
        }
        return nil
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
        return ~crc
    }

    private static func decompressNVZlibData(_ data: Data) -> Data? {
        guard data.count > 4 else { return nil }

        let sizeTrailer = data.suffix(4)
        let expectedSize = sizeTrailer.reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        let compressedData = data.dropLast(4)
        guard expectedSize > 0 else { return nil }

        var destination = Data(count: Int(expectedSize))
        let decodedSize = destination.withUnsafeMutableBytes { destinationBuffer in
            compressedData.withUnsafeBytes { sourceBuffer in
                compression_decode_buffer(
                    destinationBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    Int(expectedSize),
                    sourceBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    compressedData.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard decodedSize == Int(expectedSize) else {
            return nil
        }

        return destination
    }

    private static func compressNVZlibData(_ data: Data) -> Data? {
        if data.isEmpty { return nil }

        var destinationCapacity = max(64, Int(Double(data.count) * 1.1) + 16)
        var compressedSize = 0
        var compressed = Data()

        repeat {
            compressed = Data(count: destinationCapacity)
            compressedSize = compressed.withUnsafeMutableBytes { destinationBuffer in
                data.withUnsafeBytes { sourceBuffer in
                    compression_encode_buffer(
                        destinationBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        destinationCapacity,
                        sourceBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        data.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            destinationCapacity *= 2
        } while compressedSize == 0 && destinationCapacity < max(1024 * 1024 * 32, data.count * 8)

        guard compressedSize > 0 else { return nil }
        compressed.count = compressedSize

        var result = compressed
        var expectedSize = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &expectedSize) { bytes in
            result.append(contentsOf: bytes)
        }
        return result
    }
}

extension UUID {
    var uuidData: Data {
        var uuid = uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }

    init?(data: Data) {
        guard data.count == MemoryLayout<uuid_t>.size else { return nil }
        let uuid = data.withUnsafeBytes { rawBuffer -> uuid_t in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        }
        self.init(uuid: uuid)
    }
}
