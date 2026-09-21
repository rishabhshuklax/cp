import AppKit
import CpKit
import SwiftUI

@main
@MainActor
struct CpApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let controller = AppController.shared

    var body: some Scene {
        // The menu-bar item is a fallback, not the primary surface. The picker is
        // centred on screen and reached with ⇧⌘V; anchoring the main UI to a
        // menu-bar extra is what forces every other clipboard manager to stay
        // narrow enough to fit underneath it.
        MenuBarExtra("cp", systemImage: "doc.on.clipboard") {
            MenuBarContent(controller: controller)
        }

        Window("Clipboard", id: WindowID.browser) {
            BrowserView(
                model: controller.pickerModel,
                archive: controller.archive,
                onTogglePin: { controller.store.togglePin($0) },
                onDelete: { controller.store.delete($0) },
                onCopy: { controller.choose($0, asPlainText: false) }
            )
            .onAppear { controller.pickerModel.refresh() }
        }
        .defaultSize(width: 980, height: 620)

        Settings {
            SettingsView(settings: controller.settings, controller: controller)
        }
    }
}

enum WindowID {
    static let browser = "browser"
}

private struct MenuBarContent: View {
    let controller: AppController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open picker") { controller.showPicker() }
            .keyboardShortcut("v", modifiers: [.command, .shift])

        Divider()

        Button("Browse history…") {
            // The app runs as an accessory, so it has to be brought forward
            // explicitly before a regular window will take focus.
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: WindowID.browser)
        }

        SettingsLink { Text("Settings…") }

        Divider()

        Button("Clear unpinned history") {
            controller.store.clearUnpinned()
            controller.pickerModel.refresh()
        }

        Divider()

        Button("Quit cp") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Starts and stops the capture pipeline alongside the app.
final class AppDelegate: NSObject, NSApplicationDelegate {

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppController.shared.start()
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        AppController.shared.stop()
    }
}
