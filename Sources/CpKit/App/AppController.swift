import AppKit
import Observation
import SwiftUI

/// Owns the running app: the engine pieces, and (as the redesign lands) the
/// surfaces built on them.
@Observable
@MainActor
public final class AppController {

    public let settings: Settings
    public let store: ClippingStore
    public let archive: ClippingArchive?
    public let links: LinkPreviews

    let monitor: PasteboardMonitor
    let paster: PasteWriting
    private let pickerHotKey = GlobalHotKey()

    public private(set) var lastError: String?

    /// The real app: settings from `UserDefaults`, history from Application
    /// Support, the system pasteboard.
    public convenience init() {
        self.init(settings: Settings(), archive: try? ClippingArchive(), pasteboard: .general)
    }

    public init(settings: Settings, archive: ClippingArchive?, pasteboard: NSPasteboard) {
        self.settings = settings
        self.archive = archive
        let store = ClippingStore(archive: archive, settings: settings)
        self.store = store
        self.links = LinkPreviews(store: store, settings: settings)
        self.paster = Paster(pasteboard: pasteboard)
        self.monitor = PasteboardMonitor(pasteboard: pasteboard, settings: settings, archive: archive)

        monitor.onCapture = { [weak self] clipping, secret in
            self?.store.ingest(clipping, secret: secret)
        }
    }

    public func start() {
        // Accessory: no Dock icon, no menu of its own. This is a utility that
        // lives behind a keystroke.
        NSApp.setActivationPolicy(.accessory)
        monitor.start()
        registerHotKey()
    }

    public func stop() {
        monitor.stop()
        pickerHotKey.unregister()
    }

    // MARK: - Hot key

    func registerHotKey() {
        let registered = pickerHotKey.register(settings.hotKey) { [weak self] in
            self?.hotKeyPressed()
        }
        lastError = registered ? nil : "Taken by another app"
    }

    private func hotKeyPressed() {}

    // MARK: - Permissions

    public var canPaste: Bool { paster.canPaste }

    public func requestPastePermission() {
        paster.requestPermission()
    }

    public func clearError() { lastError = nil }
}

extension AppController {
    /// Single shared instance.
    ///
    /// The app delegate starts the capture pipeline at launch and the scene tree
    /// reads the same store — without one owner they end up as two controllers,
    /// each polling the pasteboard, each with half the history.
    public static let shared = AppController()
}
