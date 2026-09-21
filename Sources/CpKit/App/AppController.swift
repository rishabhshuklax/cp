import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// Owns the running app: the engine, the surfaces, the hot keys, and the one
/// question every one of them ends up asking — which app is this going into?
@Observable
@MainActor
public final class AppController: PickerHost, LibraryHost {

    public let settings: Settings
    public let store: ClippingStore
    public let archive: ClippingArchive?
    public let links: LinkPreviews
    public let toasts = ToastCenter()
    public let stack: PasteStack
    public let pickerModel: PickerModel
    public let libraryModel: LibraryModel

    let monitor: PasteboardMonitor
    let paster: PasteWriting

    private let pickerHotKey = GlobalHotKey()
    private let libraryHotKey = GlobalHotKey()
    private var picker: PickerWindow!
    private var toastWindow: ToastWindow!
    private var library: LibraryWindow!
    private var settingsWindow: SettingsWindow!
    private let chip = FormatChipWindow()
    public private(set) var switcher: QuickSwitch!
    private var switcherWindow: SwitcherWindow!

    /// The app the paste is aimed at, captured when the picker opens: by the
    /// time you choose, the answer can have changed.
    private var pasteTarget: NSRunningApplication?
    /// The last app that was frontmost other than cp, for when the Library is
    /// in front and the frontmost app *is* cp.
    private var lastOtherApp: NSRunningApplication?
    private var lastDeleted: DeletedClipping?

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
        let paster = Paster(pasteboard: pasteboard)
        self.paster = paster
        self.monitor = PasteboardMonitor(pasteboard: pasteboard, settings: settings, archive: archive)
        self.stack = PasteStack(store: store, settings: settings, paster: paster)
        self.pickerModel = PickerModel(store: store, settings: settings, links: links, stack: stack)
        self.libraryModel = LibraryModel(store: store, settings: settings, links: links)

        monitor.onCapture = { [weak self] clipping, secret in
            self?.store.ingest(clipping, secret: secret)
        }
        stack.ignoreChange = { [weak self] count in self?.monitor.ignore(changeCount: count) }
        stack.toast = { [weak self] text in self?.toasts.show(text) }
        pickerModel.host = self
        libraryModel.host = self

        picker = PickerWindow(model: pickerModel)
        library = LibraryWindow(model: libraryModel)
        settingsWindow = SettingsWindow(controller: self)
        toastWindow = ToastWindow(center: toasts)
        picker.onHide = { [weak self] in
            // Clips left in the stack take over ⌘V once the picker is gone.
            self?.stack.armIfNeeded()
        }

        switcher = QuickSwitch(
            isHoldingModifiers: { [weak self] in
                guard let self else { return false }
                return NSEvent.modifierFlags.contains(self.settings.hotKey.anchorModifier)
            },
            clipCount: { [weak self] in
                min(Theme.Metric.hudCards, self?.store.clippings.count ?? 0)
            },
            holdToSwitch: { [weak self] in self?.settings.holdToSwitch ?? false }
        )
        switcherWindow = SwitcherWindow(store: store, links: links, switcher: switcher)
        switcher.handleEvents { [weak self] event in self?.apply(event) }
    }

    // MARK: - Quick switch

    /// What the state machine decided, carried out.
    private func apply(_ event: QuickSwitch.Event) {
        switch event {
        case .openPicker:
            showPicker()
        case .closePicker:
            hidePicker()
        case .showHUD(let index):
            pasteTarget = currentTarget()
            hidePicker()
            switcherWindow.show(index: index, clippings: recentForSwitcher())
        case .selectHUD(let index):
            switcherWindow.update(index: index)
        case .hideHUD:
            switcherWindow.hide()
        case .paste(let index):
            let clippings = switcherWindow.current
            switcherWindow.hide()
            guard clippings.indices.contains(index) else { return }
            let clipping = clippings[index]
            paste(clipping, as: PasteFormats.defaultFormat(for: clipping, settings: settings))
        }
    }

    /// The most recent clips, newest first — the same order ⌘V walks back
    /// through, which is what makes the second card the obvious first stop.
    private func recentForSwitcher() -> [Clipping] {
        Array(store.clippings.prefix(Theme.Metric.hudCards))
    }

    public func start() {
        // Accessory: no Dock icon, no menu of its own. This is a utility that
        // lives behind a keystroke.
        NSApp.setActivationPolicy(.accessory)
        monitor.start()
        registerHotKey()
        // Skipped silently when something else owns it: the menu bar opens the
        // Library too, and a shortcut clash is not worth an alert at launch.
        libraryHotKey.register(HotKeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey))) { [weak self] in
            self?.openLibrary()
        }
        watchFrontmostApp()
        observeToasts()
    }

    public func stop() {
        chip.hide()
        monitor.stop()
        pickerHotKey.unregister()
        libraryHotKey.unregister()
        stack.disarm()
        switcher.cancel()
    }

    // MARK: - Hot keys

    public func registerHotKey() {
        let registered = pickerHotKey.register(settings.hotKey) { [weak self] in
            self?.hotKeyPressed()
        }
        lastError = registered ? nil : "Taken by another app"
    }

    private func hotKeyPressed() {
        switcher.hotKeyPressed(pickerVisible: picker.isVisible)
    }

    // MARK: - The picker

    public var isPickerVisible: Bool { picker.isVisible }

    public func showPicker() {
        pasteTarget = currentTarget()
        picker.show()
    }

    public func hidePicker() {
        picker.hide()
    }

    public func togglePicker() {
        picker.isVisible ? hidePicker() : showPicker()
    }

    // MARK: - Paste target

    private var ownBundleID: String? { Bundle.main.bundleIdentifier }

    private func currentTarget() -> NSRunningApplication? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let frontmost, frontmost.bundleIdentifier == ownBundleID { return lastOtherApp }
        return frontmost ?? lastOtherApp
    }

    private func watchFrontmostApp() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                guard app.bundleIdentifier != self?.ownBundleID else { return }
                self?.lastOtherApp = app
            }
        }
    }

    private func observeToasts() {
        withObservationTracking {
            _ = toasts.current
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.toastWindow.update()
                self?.observeToasts()
            }
        }
    }

    // MARK: - PickerHost

    public var canPaste: Bool { paster.canPaste }

    public func paste(_ clipping: Clipping, as format: PasteFormat) {
        guard let payload = PasteRenderer.payload(for: clipping, as: format, store: store)
                ?? PasteRenderer.payload(for: clipping, as: .original, store: store) else {
            hidePicker()
            toasts.show(clipping.isConcealed ? "That password is gone" : "Nothing to paste")
            return
        }
        monitor.ignore(changeCount: paster.write(payload))
        // Hidden before the keystroke: the target has to be frontmost first.
        hidePicker()
        chip.hide()
        paster.paste(into: pasteTarget, automatic: settings.pasteAutomatically) { [weak self] outcome in
            self?.report(outcome, for: clipping, format: format)
        }
    }

    private func report(_ outcome: PasteOutcome, for clipping: Clipping, format: PasteFormat) {
        switch outcome {
        case .pasted(let appName):
            toasts.show("Pasted into \(appName ?? "the app")")
            showChip(for: clipping, used: format)
        case .copiedOnly:
            toasts.show("Copied · press ⌘V")
        }
    }

    /// The other formats this clipping could have gone in, offered where it
    /// landed. Only for clippings that have another format worth offering.
    private func showChip(for clipping: Clipping, used: PasteFormat) {
        let formats = PasteFormats.chip(for: clipping)
        guard formats.count > 1 else {
            chip.hide()
            return
        }
        let selected = formats.contains(used) ? used : formats[0]
        chip.show(clipping: clipping, formats: formats, selected: selected, target: pasteTarget) { [weak self] format in
            self?.replacePaste(of: clipping, with: format)
        }
    }

    /// Swaps the paste just made for another format: ⌘Z, write, ⌘V. The write
    /// carries cp's own marker, so the monitor does not capture it back.
    private func replacePaste(of clipping: Clipping, with format: PasteFormat) {
        guard let payload = PasteRenderer.payload(for: clipping, as: format, store: store) else { return }
        showChip(for: clipping, used: format)
        paster.replaceLastPaste(with: payload, in: pasteTarget) { [weak self] outcome in
            guard case .copiedOnly = outcome else { return }
            self?.toasts.show("Copied · press ⌘V")
        }
    }

    public func pasteStackInOrder() {
        let target = pasteTarget ?? currentTarget()
        hidePicker()
        stack.pasteInOrder(into: target)
    }

    public func closePicker() {
        hidePicker()
    }

    public func openSettings() {
        hidePicker()
        chip.hide()
        settingsWindow.show()
    }

    /// Everything kept, and what it takes up on disk. Measured off the main
    /// thread: the assets folder can hold a few hundred screenshots.
    public func historySummary() async -> String {
        let clips = store.clippings.filter { !$0.isConcealed }.count
        let count = clips == 1 ? "1 clip" : "\(Self.decimal.string(from: NSNumber(value: clips)) ?? "\(clips)") clips"
        guard let directory = archive?.assetsDirectory.deletingLastPathComponent() else { return count }
        let bytes = await Task.detached(priority: .utility) { Self.directorySize(directory) }.value
        return "\(count) · \(ByteFormat.short(bytes))"
    }

    nonisolated private static func directorySize(_ directory: URL) -> Int {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var total = 0
        for case let url as URL in files {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            total += values?.fileSize ?? 0
        }
        return total
    }

    public func clearHistory() {
        store.clearUnpinned()
        stack.clear()
        toasts.show("History cleared")
    }

    private static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    // MARK: - Capture state, for the menu bar

    public var isPaused: Bool {
        guard let until = monitor.pausedUntil else { return false }
        return until > Date()
    }

    /// "Saving what you copy", or when it starts again.
    public var captureState: String {
        guard let until = monitor.pausedUntil, until > Date() else { return "Saving what you copy" }
        guard until != .distantFuture else { return "Paused" }
        return "Paused · resumes \(RelativeTime.clock(until))"
    }

    public func togglePause() {
        if isPaused {
            monitor.resume()
            toasts.show("Saving what you copy")
        } else {
            monitor.pause(for: 600)
            toasts.show("Paused for 10 minutes")
        }
    }

    /// The five most recent clippings, passwords left out.
    public func recentForMenu(limit: Int = 5) -> [Clipping] {
        Array(store.clippings.lazy.filter { !$0.isConcealed }.prefix(limit))
    }

    // MARK: - The Library

    public var isLibraryVisible: Bool { library.isVisible }

    public func openLibrary() {
        hidePicker()
        chip.hide()
        library.show()
    }

    // MARK: - LibraryHost

    public func copyToClipboard(_ clipping: Clipping) {
        let format = PasteFormats.defaultFormat(for: clipping, settings: settings)
        guard let payload = PasteRenderer.payload(for: clipping, as: format, store: store) else { return }
        monitor.ignore(changeCount: paster.write(payload))
        toasts.show("Copied · press ⌘V")
    }

    public func delete(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        if ids.count == 1, let clipping = store.clipping(withID: ids[0]) {
            delete(clipping)
            return
        }
        ids.forEach { id in if stack.contains(id) { stack.toggle(id) } }
        store.delete(ids)
        libraryModel.clearSelection()
        toasts.show("Deleted \(ids.count)")
    }

    public func setPinned(_ ids: [UUID], pinned: Bool) {
        store.setPinned(ids, pinned)
        toasts.show(pinned ? "Pinned \(ids.count)" : "Unpinned \(ids.count)")
    }

    public func addToStack(_ ids: [UUID]) {
        for id in ids where !stack.contains(id) { stack.toggle(id) }
        toasts.show("\(stack.count) in the stack")
    }

    public func openLink(_ clipping: Clipping) {
        guard let url = LinkResolver.normalizedURL(clipping.payload) else { return }
        hidePicker()
        NSWorkspace.shared.open(url)
    }

    public func openSource(_ clipping: Clipping) {
        guard let source = clipping.sourceURL, let url = LinkResolver.normalizedURL(source) else { return }
        hidePicker()
        NSWorkspace.shared.open(url)
    }

    public func revealInFinder(_ clipping: Clipping) {
        let urls = PasteFormats.paths(of: clipping).map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        hidePicker()
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    public func saveImageToDesktop(_ clipping: Clipping) {
        guard let file = clipping.assetFilename, let source = store.assetURL(file),
              let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else { return }
        hidePicker()
        let stamp = Self.fileStamp.string(from: clipping.lastCopiedAt)
        var destination = desktop.appendingPathComponent("Clipboard \(stamp).png")
        var attempt = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = desktop.appendingPathComponent("Clipboard \(stamp) (\(attempt)).png")
            attempt += 1
        }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            toasts.show("Saved to Desktop")
        } catch {
            toasts.show("Could not save that image")
        }
    }

    public func togglePin(_ clipping: Clipping) {
        store.togglePin(clipping.id)
        toasts.show(clipping.isPinned ? "Unpinned" : "Pinned")
    }

    public func delete(_ clipping: Clipping) {
        if stack.contains(clipping.id) { stack.toggle(clipping.id) }
        guard let deleted = store.delete(clipping.id) else {
            // A password: forgotten outright, with nothing to undo.
            toasts.show("Password forgotten")
            return
        }
        lastDeleted = deleted
        toasts.show("Deleted") { [weak self] in self?.undoDelete() }
    }

    public func forget(_ clipping: Clipping) {
        store.forget(clipping.id)
        toasts.show("Password forgotten")
    }

    public func undoDelete() {
        guard let lastDeleted else { return }
        store.restore(lastDeleted)
        self.lastDeleted = nil
        toasts.show("Restored")
    }

    public func requestPastePermission() {
        paster.requestPermission()
    }

    // MARK: - Permissions

    public func clearError() { lastError = nil }

    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()
}

extension AppController {
    /// Single shared instance.
    ///
    /// The app delegate starts the capture pipeline at launch and the scene tree
    /// reads the same store — without one owner they end up as two controllers,
    /// each polling the pasteboard, each with half the history.
    public static let shared = AppController()
}
