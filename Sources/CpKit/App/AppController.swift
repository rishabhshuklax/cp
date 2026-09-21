import AppKit
import Observation
import SwiftUI

/// Wires the pieces together and owns the picker's lifecycle.
@Observable
@MainActor
public final class AppController {

    public let settings: Settings
    public let store: ClippingStore
    public let archive: ClippingArchive?
    public let pickerModel: PickerModel

    private let monitor: PasteboardMonitor
    private let paster: Paster
    private let hotKey = GlobalHotKey()
    private let linkResolver = LinkResolver()

    private var panel: PickerPanel?
    /// The app that was frontmost when the picker opened — the one the paste is
    /// aimed at. Captured at open time because by the time the user chooses, the
    /// answer may have changed.
    private var pasteTarget: NSRunningApplication?

    public private(set) var isPickerVisible = false
    public private(set) var lastError: String?

    public init() {
        let archive = try? ClippingArchive()
        let settings = Settings()

        self.archive = archive
        self.settings = settings
        self.store = ClippingStore(archive: archive, settings: settings)
        self.paster = Paster(archive: archive)
        self.monitor = PasteboardMonitor(settings: settings, archive: archive)
        self.pickerModel = PickerModel(store: store, settings: settings, linkResolver: linkResolver)

        monitor.onCapture = { [weak self] clipping in
            self?.store.ingest(clipping)
        }
    }

    public func start() {
        // Accessory: no Dock icon, no menu bar of its own. This is a utility that
        // lives behind a keystroke.
        NSApp.setActivationPolicy(.accessory)
        monitor.start()

        let registered = hotKey.register(.shiftCommandV) { [weak self] in
            self?.togglePicker()
        }
        if !registered {
            lastError = "Couldn't register ⇧⌘V — another app may already own it."
        }
    }

    public func stop() {
        monitor.stop()
        hotKey.unregister()
    }

    // MARK: - Picker lifecycle

    public func togglePicker() {
        isPickerVisible ? hidePicker() : showPicker()
    }

    public func showPicker() {
        pasteTarget = NSWorkspace.shared.frontmostApplication
        pickerModel.prepare(targetBundleID: pasteTarget?.bundleIdentifier)

        let panel = existingOrNewPanel()
        panel.positionOnActiveScreen()
        panel.makeKeyAndOrderFront(nil)
        isPickerVisible = true
        pickerModel.resolveLinkIfNeeded()
    }

    public func hidePicker() {
        panel?.orderOut(nil)
        isPickerVisible = false
    }

    private func existingOrNewPanel() -> PickerPanel {
        if let panel { return panel }

        let rect = NSRect(
            x: 0, y: 0,
            width: Theme.Metric.panelWidth,
            height: Theme.Metric.panelHeight
        )
        let panel = PickerPanel(contentRect: rect)

        let view = PickerView(
            model: pickerModel,
            archive: archive,
            onChoose: { [weak self] clipping, plainText in
                self?.choose(clipping, asPlainText: plainText)
            },
            onTransform: { [weak self] clipping, transform in
                self?.applyTransform(transform, to: clipping)
            },
            onTogglePin: { [weak self] id in
                self?.store.togglePin(id)
                self?.pickerModel.refresh()
            },
            onDelete: { [weak self] id in
                self?.store.delete(id)
                self?.pickerModel.refresh()
            },
            onDismiss: { [weak self] in
                self?.hidePicker()
            }
        )

        let hosting = NSHostingView(rootView: view)
        hosting.frame = rect
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    // MARK: - Choosing

    public func choose(_ clipping: Clipping, asPlainText: Bool) {
        guard !clipping.isConcealed else {
            lastError = "That clipping was never stored."
            hidePicker()
            return
        }

        paster.writeToPasteboard(clipping, asPlainText: asPlainText)
        monitor.suppressNextChange()
        finishPaste()
    }

    public func applyTransform(_ transform: Transform, to clipping: Clipping) {
        let transformed = transform.apply(clipping.payload)
        paster.writeRawText(transformed)
        monitor.suppressNextChange()
        finishPaste()
    }

    private func finishPaste() {
        hidePicker()

        guard settings.pasteAutomatically else { return }
        guard paster.hasAccessibilityPermission else {
            lastError = "Copied. Grant Accessibility access to paste automatically."
            return
        }

        // The panel is non-activating, so the target should still be frontmost —
        // but re-activating costs nothing and covers the case where something else
        // grabbed focus while the picker was open.
        pasteTarget?.activate()

        // Let the panel finish ordering out and the target settle before the
        // synthetic ⌘V, or the keystroke lands in a window that is going away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                _ = self?.paster.synthesizePaste()
            }
        }
    }

    // MARK: - Permissions

    public var hasAccessibilityPermission: Bool { paster.hasAccessibilityPermission }

    public func requestAccessibilityPermission() {
        paster.requestAccessibilityPermission()
    }

    public func clearError() { lastError = nil }
}

extension AppController {
    /// Single shared instance.
    ///
    /// The app delegate has to start the capture pipeline at launch, and the
    /// SwiftUI scene tree has to read the same store — without one owner they end
    /// up as two `AppController`s, each polling the pasteboard, each with half the
    /// history. A menu-bar utility has exactly one of these by construction, so a
    /// shared instance is the honest way to say so.
    public static let shared = AppController()
}
