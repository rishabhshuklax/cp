import AppKit
import CpKit
import SwiftUI

@main
@MainActor
struct CpApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let controller = AppController.shared

    var body: some Scene {
        MenuBarExtra {
            Button("Quit cp") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "list.clipboard")
        }
        .menuBarExtraStyle(.window)
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
