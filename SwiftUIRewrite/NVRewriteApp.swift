import SwiftUI
import AppKit

@MainActor
final class NVWindowActivationBridge {
    static let shared = NVWindowActivationBridge()
    var openMainWindow: (() -> Void)?
}

@main
struct NVRewriteApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(NVRewriteAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState(repository: JSONNoteRepository.defaultRepository())

    var body: some Scene {
        let _ = NVWindowActivationBridge.shared.openMainWindow = {
            openWindow(id: "main")
        }

        WindowGroup("Notation", id: "main") {
            MainWindowView()
                .environmentObject(appState)
                .frame(minWidth: 960, minHeight: 640)
                .onOpenURL { url in
                    appState.handleIncomingURL(url)
                }
        }
        .commands {
            NVCommands(appState: appState)
        }

        Settings {
            PreferencesRootView()
                .environmentObject(appState)
                .frame(width: 760, height: 520)
        }
    }
}

final class NVRewriteAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let image = iconImage() {
            NSApp.applicationIconImage = image
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func iconImage() -> NSImage? {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let candidateURLs = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Images/Notality.icns"),
            executableURL.deletingLastPathComponent()
                .appendingPathComponent("NVRewrite_NVRewrite.resources/Notality.icns"),
            executableURL.deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("NVRewrite_NVRewrite.resources/Notality.icns"),
            executableURL.deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Images/Notality.icns")
        ]

        for candidateURL in candidateURLs where FileManager.default.fileExists(atPath: candidateURL.path) {
            if let image = NSImage(contentsOf: candidateURL) {
                return image
            }
        }

        return nil
    }
}
