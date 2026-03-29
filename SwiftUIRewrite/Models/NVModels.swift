import AppKit
import Foundation

enum LayoutStyle: String, CaseIterable, Identifiable, Codable {
    case vertical
    case horizontal

    var id: String { rawValue }
}

enum SidebarMode: String, CaseIterable, Identifiable, Codable {
    case notes
    case tags
    case bookmarks
    case savedSearches

    var id: String { rawValue }
}

enum NoteSortField: String, CaseIterable, Identifiable, Codable {
    case title
    case labels
    case modified
    case created

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .title: "Title"
        case .labels: "Labels"
        case .modified: "Date Modified"
        case .created: "Date Created"
        }
    }
}

struct SyncServiceState: Identifiable, Hashable, Codable {
    enum Status: String, Codable {
        case idle
        case syncing
        case error
    }

    let id: String
    var displayName: String
    var status: Status
    var detail: String
}

struct SavedSearchItem: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var query: String
    var selectedNoteID: UUID?
}

struct NoteBookmark: Identifiable, Hashable, Codable {
    let id: UUID
    var noteID: UUID
    var title: String
    var searchString: String
}

struct TagItem: Identifiable, Hashable {
    let id: UUID
    var name: String
    var noteCount: Int
}

struct EditorSelection: Hashable {
    var range: NSRange
    var wasAutomatic = false
}

struct Note: Identifiable {
    let id: UUID
    var title: String
    var body: NSAttributedString
    var plainBody: String
    var labels: [String]
    var createdAt: Date
    var modifiedAt: Date
    var selectedRange: NSRange
    var fileURL: URL?
    var syncMetadata: [String: String]

    init(
        id: UUID = UUID(),
        title: String,
        body: NSAttributedString,
        labels: [String] = [],
        createdAt: Date = .now,
        modifiedAt: Date = .now,
        selectedRange: NSRange = .init(location: 0, length: 0),
        fileURL: URL? = nil,
        syncMetadata: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.plainBody = body.string
        self.labels = labels
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.selectedRange = selectedRange
        self.fileURL = fileURL
        self.syncMetadata = syncMetadata
    }

    var preview: String {
        let condensed = plainBody
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return condensed
    }

    var labelsText: String {
        labels.joined(separator: ", ")
    }

    func matches(searchText: String, tagFilter: String?) -> Bool {
        let normalizedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matchesTag = tagFilter.map { filterTag in
            labels.contains { label in
                label.caseInsensitiveCompare(filterTag) == .orderedSame
            }
        } ?? true

        guard !normalizedQuery.isEmpty else {
            return matchesTag
        }

        if normalizedQuery.hasPrefix("\""), normalizedQuery.hasSuffix("\""), normalizedQuery.count > 1 {
            let phrase = String(normalizedQuery.dropFirst().dropLast())
            return matchesTag && searchableText.contains(phrase)
        }

        let tokens = normalizedQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        return matchesTag && tokens.allSatisfy { searchableText.contains($0) }
    }

    private var searchableText: String {
        ([title] + labels + [plainBody]).joined(separator: " ").lowercased()
    }
}

struct NVPreferences: Equatable, Codable {
    var layoutStyle: LayoutStyle = .horizontal
    var sortField: NoteSortField = .modified
    var sortReversed = true
    var showsPreviewInTitleColumn = true
    var highlightsSearchTerms = true
    var lastSelectedPreferencesPane = "general"
    var noteBodyFontName = "Menlo"
    var noteBodyFontSize: CGFloat = 14
    var tableTitleFontSize: CGFloat = 13
    var tablePreviewFontSize: CGFloat = 11
    var tableMetadataFontSize: CGFloat = 11
    var foregroundColor = ColorValue(red: 0.08, green: 0.08, blue: 0.09)
    var backgroundColor = ColorValue(red: 0.97, green: 0.97, blue: 0.96)
    var searchHighlightColor = ColorValue(red: 1.0, green: 0.95, blue: 0.55)
    var confirmDeletion = true
    var quitWhenClosingWindow = false
    var autoCompleteSearches = true
    var makeURLsClickable = true
    var linksAutoSuggested = true
    var checkSpelling = true
    var softTabs = true
    var tabWidth = 4
    var pastePreservesStyle = false
    var secureTextEntry = false
    var noteStorageFormat = "Plain Text (.txt)"
    var activationHotKey = ActivationHotKey()
    var legacyStorage = LegacyStorageStatus()
}

struct ActivationHotKey: Equatable, Codable {
    var isEnabled = false
    var keyCode: UInt16 = 17
    var modifierFlagsRawValue: UInt = NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.option.rawValue

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
    }

    var displayString: String {
        guard isEnabled else { return "Disabled" }

        let flags = modifierFlags
        var parts: [String] = []
        if flags.contains(.control) { parts.append("Control") }
        if flags.contains(.option) { parts.append("Option") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.command) { parts.append("Command") }
        parts.append(Self.displayKey(for: keyCode))
        return parts.joined(separator: "-")
    }

    static func displayKey(for keyCode: UInt16) -> String {
        switch keyCode {
        case 0: "A"
        case 1: "S"
        case 2: "D"
        case 3: "F"
        case 4: "H"
        case 5: "G"
        case 6: "Z"
        case 7: "X"
        case 8: "C"
        case 9: "V"
        case 11: "B"
        case 12: "Q"
        case 13: "W"
        case 14: "E"
        case 15: "R"
        case 16: "Y"
        case 17: "T"
        case 18: "1"
        case 19: "2"
        case 20: "3"
        case 21: "4"
        case 22: "6"
        case 23: "5"
        case 24: "="
        case 25: "9"
        case 26: "7"
        case 27: "-"
        case 28: "8"
        case 29: "0"
        case 30: "]"
        case 31: "O"
        case 32: "U"
        case 33: "["
        case 34: "I"
        case 35: "P"
        case 37: "L"
        case 38: "J"
        case 39: "'"
        case 40: "K"
        case 41: ";"
        case 42: "\\"
        case 43: ","
        case 44: "/"
        case 45: "N"
        case 46: "M"
        case 47: "."
        case 49: "Space"
        case 36: "Return"
        case 48: "Tab"
        case 51: "Delete"
        case 53: "Escape"
        case 123: "Left Arrow"
        case 124: "Right Arrow"
        case 125: "Down Arrow"
        case 126: "Up Arrow"
        default: "Key \(keyCode)"
        }
    }
}

struct ColorValue: Equatable, Codable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1.0
}

extension ColorValue {
    var nsColor: NSColor {
        NSColor(
            calibratedRed: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }
}
