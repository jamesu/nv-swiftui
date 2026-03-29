import AppKit
import SwiftUI

struct NVCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                appState.undoCurrentNote()
            }
            .keyboardShortcut("z", modifiers: [.command])
            .disabled(!appState.canUndoCurrentNote)

            Button("Redo") {
                appState.redoCurrentNote()
            }
            .keyboardShortcut("Z", modifiers: [.command, .shift])
            .disabled(!appState.canRedoCurrentNote)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Note") {
                _ = appState.createNoteIfNecessary()
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(appState.isCurrentBackendReadOnly)
        }

        CommandMenu("Notes") {
            Button("Import Notes...") {
                appState.importNotesFromFiles()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])

            Button("Delete") {
                appState.requestDeleteSelectedNotes()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(appState.isCurrentBackendReadOnly || appState.selectedNoteIDs.isEmpty)

            Button("Reveal in Finder") {
                appState.revealSelectedNoteInFinder()
            }
            .disabled(appState.selectedNoteID == nil)

            Button("Open in External Editor") {
                appState.openSelectedNoteInExternalEditor()
            }
            .disabled(appState.selectedNoteID == nil)

            Button("Export Selected Notes") {
                appState.exportSelectedNotes()
            }
            .disabled(appState.selectedNoteIDs.isEmpty)

            Button("Print Selected Notes") {
                appState.printSelectedNotes()
            }
            .keyboardShortcut("p", modifiers: [.command])
            .disabled(appState.selectedNoteIDs.isEmpty)

            Button("Repair Text Encoding...") {
                appState.promptToRepairSelectedNoteEncoding()
            }
            .disabled(!appState.canRepairSelectedNoteEncoding)

            Button("Reload From Active Storage") {
                appState.reloadNotesFromActiveStorage()
            }
            .disabled(
                (appState.preferences.legacyStorage.backend == .legacyFileDirectory ||
                appState.preferences.legacyStorage.backend == .legacySingleDatabase) &&
                appState.preferences.legacyStorage.notesDirectoryPath.isEmpty
            )

            Button("Save Search") {
                appState.saveCurrentSearch()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button("Add Bookmark") {
                appState.addBookmarkForSelection()
            }
            .keyboardShortcut("d", modifiers: [.command])
        }

        CommandMenu("View") {
            Button(appState.preferences.layoutStyle == .horizontal ? "Switch to Vertical Layout" : "Switch to Horizontal Layout") {
                appState.toggleLayout()
            }

            Toggle("Show Note Previews in Title", isOn: $appState.preferences.showsPreviewInTitleColumn)
        }

        CommandMenu("Format") {
            Button("Show Fonts") {
                NVEditorTextView.showFontPanelForActiveTextView()
            }
            .keyboardShortcut("t", modifiers: [.command])
            .disabled(appState.selectedNoteID == nil || appState.isCurrentBackendReadOnly || !appState.selectedNoteSupportsFormatting)

            Divider()

            Button("Bold") {
                NVEditorTextView.toggleBoldOnActiveTextView()
            }
            .keyboardShortcut("b", modifiers: [.command])
            .disabled(appState.selectedNoteID == nil || appState.isCurrentBackendReadOnly || !appState.selectedNoteSupportsFormatting)

            Button("Italic") {
                NVEditorTextView.toggleItalicsOnActiveTextView()
            }
            .keyboardShortcut("i", modifiers: [.command])
            .disabled(appState.selectedNoteID == nil || appState.isCurrentBackendReadOnly || !appState.selectedNoteSupportsFormatting)

            Button("Underline") {
                NVEditorTextView.toggleUnderlineOnActiveTextView()
            }
            .keyboardShortcut("u", modifiers: [.command])
            .disabled(appState.selectedNoteID == nil || appState.isCurrentBackendReadOnly || !appState.selectedNoteSupportsFormatting)

            Button("Strikethrough") {
                NVEditorTextView.toggleStrikethroughOnActiveTextView()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(appState.selectedNoteID == nil || appState.isCurrentBackendReadOnly || !appState.selectedNoteSupportsFormatting)

            Divider()

            Button("Align Left") {
                NVEditorTextView.alignLeftOnActiveTextView()
            }
            .disabled(appState.selectedNoteID == nil || appState.isCurrentBackendReadOnly || !appState.selectedNoteSupportsFormatting)

            Button("Align Center") {
                NVEditorTextView.alignCenterOnActiveTextView()
            }
            .disabled(appState.selectedNoteID == nil || appState.isCurrentBackendReadOnly || !appState.selectedNoteSupportsFormatting)

            Button("Align Right") {
                NVEditorTextView.alignRightOnActiveTextView()
            }
            .disabled(appState.selectedNoteID == nil || appState.isCurrentBackendReadOnly || !appState.selectedNoteSupportsFormatting)

            Divider()

            Button("Increase Indent") {
                NVEditorTextView.increaseIndentOnActiveTextView()
            }
            .keyboardShortcut("]", modifiers: [.command])
            .disabled(appState.selectedNoteID == nil || appState.isCurrentBackendReadOnly || !appState.selectedNoteSupportsFormatting)

            Button("Decrease Indent") {
                NVEditorTextView.decreaseIndentOnActiveTextView()
            }
            .keyboardShortcut("[", modifiers: [.command])
            .disabled(appState.selectedNoteID == nil || appState.isCurrentBackendReadOnly || !appState.selectedNoteSupportsFormatting)

            Button("Toggle Bullets") {
                NVEditorTextView.toggleBulletListOnActiveTextView()
            }
            .keyboardShortcut("8", modifiers: [.command, .shift])
            .disabled(appState.selectedNoteID == nil || appState.isCurrentBackendReadOnly || !appState.selectedNoteSupportsFormatting)
        }

        CommandGroup(replacing: .appInfo) {
            Button("About Notation") {
                appState.showAboutPanel()
            }
        }

        CommandGroup(after: .help) {
            Button("How Does This Thing Work?") {
                appState.openGettingStartedHelp()
            }

            Button("Excruciatingly Useful Shortcuts") {
                appState.openKeyboardShortcutsHelp()
            }

            Button("Contact Information") {
                appState.openContactInformationHelp()
            }

            Divider()

            Button("Acknowledgments") {
                appState.openAcknowledgments()
            }

            Divider()

            Button("Notational Velocity Website") {
                appState.openProjectWebsite()
            }

            Button("Development Website") {
                appState.openDevelopmentWebsite()
            }
        }
    }
}
