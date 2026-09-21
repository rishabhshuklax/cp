import AppKit
import Carbon.HIToolbox
import Observation

/// Registers ⌘V while the stack is armed. A protocol so tests can watch it go
/// on and off without touching the real keyboard.
@MainActor
public protocol StackHotKeyRegistering: AnyObject {
    @discardableResult func register(_ handler: @escaping () -> Void) -> Bool
    func unregister()
}

/// ⌘V, registered globally, while a stack is waiting to be pasted.
@MainActor
public final class StackHotKey: StackHotKeyRegistering {
    private let hotKey = GlobalHotKey()

    public init() {}

    @discardableResult
    public func register(_ handler: @escaping () -> Void) -> Bool {
        hotKey.register(HotKeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey)), handler: handler)
    }

    public func unregister() {
        hotKey.unregister()
    }
}

/// Several clippings, queued to paste one after another.
///
/// Two ways out: "Paste 3 in order" sends them all into the target a beat
/// apart, and closing the picker with clips still in the stack *arms* it — cp
/// takes over ⌘V, and each press pastes the next one. Arming is why ⌘V has to
/// be unregistered around cp's own synthesised ⌘V: without that, the stack
/// would eat its own keystroke and paste nothing.
@Observable
@MainActor
public final class PasteStack {

    public private(set) var ids: [UUID] = []
    /// True while cp owns ⌘V.
    public private(set) var isArmed = false

    @ObservationIgnored private let store: ClippingStore
    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let paster: PasteWriting
    @ObservationIgnored private let hotKey: StackHotKeyRegistering
    @ObservationIgnored private let scheduler: Scheduling
    /// Tells the monitor not to capture what we just wrote.
    @ObservationIgnored public var ignoreChange: (Int) -> Void = { _ in }
    @ObservationIgnored public var toast: (String) -> Void = { _ in }
    /// The app the armed stack pastes into: whatever is frontmost when ⌘V is
    /// pressed, which is the only honest answer once the picker has closed.
    @ObservationIgnored public var frontmostApp: () -> NSRunningApplication? = {
        NSWorkspace.shared.frontmostApplication
    }

    /// Long enough that the target app has finished handling the last paste,
    /// short enough to read as one action.
    public static let gap: TimeInterval = 0.15

    public init(
        store: ClippingStore,
        settings: Settings,
        paster: PasteWriting,
        hotKey: StackHotKeyRegistering? = nil,
        scheduler: Scheduling = MainQueueScheduler()
    ) {
        self.store = store
        self.settings = settings
        self.paster = paster
        self.hotKey = hotKey ?? StackHotKey()
        self.scheduler = scheduler
    }

    // MARK: - Contents

    public var count: Int { ids.count }
    public var isEmpty: Bool { ids.isEmpty }

    public func contains(_ id: UUID) -> Bool { ids.contains(id) }

    /// 1-based, for the badge on a stacked row's thumbnail.
    public func position(of id: UUID) -> Int? {
        ids.firstIndex(of: id).map { $0 + 1 }
    }

    /// A password is never stacked: it would be forgotten before its turn.
    public func toggle(_ id: UUID) {
        guard let clipping = store.clipping(withID: id), !clipping.isConcealed else { return }
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
        } else {
            ids.append(id)
        }
        if ids.isEmpty { disarm() }
    }

    public func clear() {
        ids = []
        disarm()
    }

    /// The clippings still in history, in stack order.
    public var clippings: [Clipping] {
        ids.compactMap { store.clipping(withID: $0) }
    }

    // MARK: - Paste in order

    /// Sends the whole stack into `target`, a beat apart. Text goes as one
    /// paste joined by newlines — three separate pastes of three lines is three
    /// undo steps and three chances for the target to autocorrect something.
    public func pasteInOrder(into target: NSRunningApplication?) {
        let clips = clippings
        guard !clips.isEmpty else { return }
        ids = []
        disarm()

        let payloads = clips.compactMap { clipping -> PastePayload? in
            PasteRenderer.payload(
                for: clipping,
                as: PasteFormats.defaultFormat(for: clipping, settings: settings),
                store: store
            )
        }
        guard !payloads.isEmpty else { return }

        if let joined = Self.joinedText(payloads) {
            send(PastePayload(string: joined), into: target) { [weak self] in
                self?.toast("Pasted \(clips.count) in order")
            }
            return
        }
        send(payloads, index: 0, into: target, count: clips.count)
    }

    /// One string when every payload is only a string; nil when any of them
    /// carries formatting, an image or a file.
    static func joinedText(_ payloads: [PastePayload]) -> String? {
        var lines: [String] = []
        for payload in payloads {
            guard payload.png == nil, payload.fileURLs == nil, payload.rtf == nil,
                  let string = payload.string else { return nil }
            lines.append(string)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func send(_ payloads: [PastePayload], index: Int, into target: NSRunningApplication?, count: Int) {
        guard payloads.indices.contains(index) else {
            toast("Pasted \(count) in order")
            return
        }
        send(payloads[index], into: target) { [weak self] in
            guard let self else { return }
            self.scheduler.run(after: Self.gap) {
                self.send(payloads, index: index + 1, into: target, count: count)
            }
        }
    }

    private func send(_ payload: PastePayload, into target: NSRunningApplication?, then: @escaping @MainActor () -> Void) {
        ignoreChange(paster.write(payload))
        paster.paste(into: target, automatic: settings.pasteAutomatically) { _ in then() }
    }

    // MARK: - Arming

    /// Called when the picker closes with clips still in the stack. Without
    /// permission to press ⌘V there is nothing to arm, and swallowing the
    /// user's own ⌘V would leave them with no way to paste at all.
    public func armIfNeeded() {
        guard !ids.isEmpty, !isArmed, settings.pasteAutomatically, paster.canPaste else { return }
        isArmed = hotKey.register { [weak self] in self?.pasteNext() }
    }

    public func disarm() {
        guard isArmed else { return }
        hotKey.unregister()
        isArmed = false
    }

    /// One ⌘V: write the next clip, hand the keystroke on, and take ⌘V back
    /// again — unless that was the last one.
    public func pasteNext() {
        guard !ids.isEmpty else {
            finish()
            return
        }
        let id = ids.removeFirst()
        guard let clipping = store.clipping(withID: id),
              let payload = PasteRenderer.payload(
                  for: clipping,
                  as: PasteFormats.defaultFormat(for: clipping, settings: settings),
                  store: store
              ) else {
            // Gone from history since it was stacked: skip it, keep the press.
            pasteNext()
            return
        }

        ignoreChange(paster.write(payload))
        // Our own ⌘V must not come back to us.
        hotKey.unregister()
        isArmed = false
        paster.paste(into: frontmostApp(), automatic: true) { [weak self] _ in
            guard let self else { return }
            guard !self.ids.isEmpty else {
                self.finish()
                return
            }
            self.scheduler.run(after: Self.gap) {
                self.isArmed = self.hotKey.register { [weak self] in self?.pasteNext() }
            }
        }
    }

    private func finish() {
        isArmed = false
        hotKey.unregister()
        toast("Stack pasted")
    }
}
