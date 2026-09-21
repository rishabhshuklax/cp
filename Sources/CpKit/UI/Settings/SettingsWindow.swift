import AppKit
import SwiftUI

/// Settings in a window of its own rather than a `Settings` scene.
///
/// The scene's `SettingsLink` only works from inside SwiftUI's own menus, and
/// cp is an accessory app whose Settings is opened from a floating panel's ⌘,
/// and from the menu bar. One window, opened the same way from both.
@MainActor
public final class SettingsWindow {

    private let controller: AppController
    private var window: NSWindow?

    public init(controller: AppController) {
        self.controller = controller
    }

    public var isVisible: Bool { window?.isVisible ?? false }

    public func show() {
        let window = existingOrNewWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    public func hide() {
        window?.orderOut(nil)
    }

    private func existingOrNewWindow() -> NSWindow {
        if let window { return window }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Theme.Metric.settingsWidth, height: Theme.Metric.settingsHeight),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(
            rootView: SettingsView(settings: controller.settings, controller: controller)
        )
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        return window
    }
}
