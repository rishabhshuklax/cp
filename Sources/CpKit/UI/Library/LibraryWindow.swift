import AppKit
import SwiftUI

/// The Library's window — an ordinary one, unlike everything else in this app.
///
/// Browsing is the one thing cp does that you do *at* cp rather than on the way
/// to somewhere else, so this window activates, takes focus, resizes and
/// behaves like any other window. cp runs as an accessory, so it has to be
/// activated by hand before the window will come forward.
@MainActor
public final class LibraryWindow: NSObject, NSWindowDelegate {

    private let model: LibraryModel
    private var window: NSWindow?

    public init(model: LibraryModel) {
        self.model = model
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

    public func toggle() {
        if isVisible, window?.isKeyWindow == true { hide() } else { show() }
    }

    private func existingOrNewWindow() -> NSWindow {
        if let window { return window }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Theme.Metric.libraryWidth, height: Theme.Metric.libraryHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "cp Library"
        // The sidebar runs to the top edge, with the traffic lights over it.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: Theme.Metric.libraryMinWidth, height: Theme.Metric.libraryMinHeight)
        window.contentView = NSHostingView(rootView: LibraryView(model: model))
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        self.window = window
        return window
    }

    public func windowWillClose(_ notification: Notification) {
        // Nothing to save: the Library is a view of the store, not a copy of it.
    }
}
