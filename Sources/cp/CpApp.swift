import AppKit
import CpKit
import SwiftUI

@main
@MainActor
struct CpApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let controller = AppController.shared

    /// Bound rather than implied: the scene is only in the menu bar while this
    /// is true, and the audit could not find cp's icon at all.
    @State private var menuBarInserted = true

    var body: some Scene {
        // `.window` rather than `.menu` so the recent rows can carry their
        // thumbnails, which is what makes them recognisable at a glance.
        MenuBarExtra(isInserted: $menuBarInserted) {
            MenuBarView(controller: controller)
        } label: {
            Image(nsImage: CpApp.menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }

    /// A template image, so it follows the menu bar's own light and dark.
    static let menuBarIcon: NSImage = {
        let image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "cp")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        return image
    }()
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
