import Foundation

enum StorageBackendKind: String, CaseIterable, Codable, Identifiable {
    case rewriteJSON
    case legacySingleDatabase
    case legacyFileDirectory

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rewriteJSON: "Rewrite JSON Store"
        case .legacySingleDatabase: "Legacy Single Database"
        case .legacyFileDirectory: "Legacy File-Backed Directory"
        }
    }
}

enum LegacyMigrationState: String, Codable {
    case notStarted
    case scaffolded
    case partiallyIntegrated
    case integrated
}

enum LegacyRecoverySource: String, Codable, Equatable {
    case database
    case journal
    case backup
}

struct SyncServicePreferences: Codable, Equatable, Identifiable {
    let id: String
    var serviceName: String
    var username: String
    var frequencyInMinutes: Int
    var isEnabled: Bool
    var shouldMerge: Bool
}

struct ExternalEditorPreference: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var bundlePath: String
    var isDefault: Bool
}

struct LegacyStorageStatus: Codable, Equatable {
    var backend: StorageBackendKind = .rewriteJSON
    var notesDirectoryPath: String = ""
    var notesDirectoryBookmarkData: Data?
    var databaseFileName: String = "Interim JSON State"
    var migrationState: LegacyMigrationState = .scaffolded
    var supportsLegacyRead = false
    var supportsLegacyWrite = false
    var supportsDirectorySync = false
    var supportsJournaling = false
    var supportsExternalFileImport = false
    var supportedFormats: [String] = ["Rewrite JSON"]
    var syncAccounts: [SyncServicePreferences] = []
    var externalEditors: [ExternalEditorPreference] = []
    var encryptionEnabled = false
    var storesPasswordInKeychain = false
    var hashIterationCount = LegacyEncryptionSupport.defaultHashIterations
    var keyLengthInBits = LegacyEncryptionSupport.defaultKeyLengthInBits
    var keychainDatabaseIdentifier: String?
    var masterSalt: Data?
    var dataSessionSalt: Data?
    var verifierKey: Data?
    var lastLoadSummary: String = "Not loaded"
    var lastLoadDetail: String = ""
    var lastRecoverySource: LegacyRecoverySource?
    var reloadsFromDiskOnActivate = true
}
