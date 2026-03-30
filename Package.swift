// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NVRewrite",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "NVRewrite", targets: ["NVRewrite"])
    ],
    targets: [
        .executableTarget(
            name: "NVRewrite",
            path: "SwiftUIRewrite",
            sources: [
                "NVRewriteApp.swift",
                "Models/NVModels.swift",
                "Models/LegacyStorageScaffold.swift",
                "Services/LegacySingleDatabaseArchive.swift",
                "Services/LegacyEncryptionSupport.swift",
                "Services/LegacyStorageAdapter.swift",
                "Services/DirectoryMonitor.swift",
                "Services/NoteRepository.swift",
                "State/AppState.swift",
                "Views/MainWindowView.swift",
                "Views/AppKitControlField.swift",
                "Views/AppKitNotesTableView.swift",
                "Views/AppKitNoteTextView.swift",
                "Commands/NVCommands.swift"
            ],
            resources: [
                .copy("../Images/Notality.icns"),
                .copy("../Acknowledgments.txt"),
                .copy("../en.lproj/How does this thing work?.nvhelp"),
                .copy("../en.lproj/Excruciatingly Useful Shortcuts.nvhelp"),
                .copy("../en.lproj/Contact Information.nvhelp")
            ]
        )
    ]
)
