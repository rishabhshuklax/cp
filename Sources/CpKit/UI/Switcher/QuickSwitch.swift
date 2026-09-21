import AppKit
import Foundation

/// Tap the shortcut, get the picker. Hold it and tap V again, get a row of
/// recent clips you can step through and drop by letting go — the ⌘-Tab move,
/// for the clipboard.
///
/// The whole thing hangs on one ambiguity: at the moment the shortcut fires,
/// nobody knows yet whether this is a tap or the start of a hold. So the press
/// starts a short watch on the modifier keys. Release inside it and it was a
/// tap; still holding at the end of it and it was a hold; press again inside it
/// and you have already answered. Modifier state comes from `NSEvent`'s class
/// property, which needs no permission at all.
@MainActor
public final class QuickSwitch {

    public enum State: Equatable {
        case idle
        /// The shortcut has fired and we are watching the modifier keys.
        case pending(deadline: Date)
        case hud(index: Int)
    }

    public enum Event: Equatable {
        case openPicker
        case closePicker
        case showHUD(index: Int)
        case selectHUD(index: Int)
        case hideHUD
        /// Let go: paste this one.
        case paste(index: Int)
    }

    /// Long enough to tell a tap from a hold, short enough that a tap does not
    /// feel like it is waiting for something.
    public static let holdWindow: TimeInterval = 0.22
    /// Modifier keys are polled as well as watched, because the HUD can become
    /// key a few milliseconds after the release that was meant to commit it.
    public static let pollInterval: TimeInterval = 0.02

    public private(set) var state: State = .idle

    private let scheduler: Scheduling
    private let now: () -> Date
    private let isHoldingModifiers: () -> Bool
    private let clipCount: () -> Int
    private let holdToSwitch: () -> Bool
    private var onEvent: (Event) -> Void = { _ in }

    public init(
        scheduler: Scheduling = MainQueueScheduler(),
        now: @escaping () -> Date = Date.init,
        isHoldingModifiers: @escaping () -> Bool,
        clipCount: @escaping () -> Int,
        holdToSwitch: @escaping () -> Bool
    ) {
        self.scheduler = scheduler
        self.now = now
        self.isHoldingModifiers = isHoldingModifiers
        self.clipCount = clipCount
        self.holdToSwitch = holdToSwitch
    }

    public func handleEvents(_ handler: @escaping (Event) -> Void) {
        onEvent = handler
    }

    // MARK: - Input

    public func hotKeyPressed(pickerVisible: Bool) {
        guard holdToSwitch() else {
            emit(pickerVisible ? .closePicker : .openPicker)
            return
        }
        switch state {
        case .hud(let index):
            // Another tap while holding: step along.
            let next = advance(from: index)
            state = .hud(index: next)
            emit(.selectHUD(index: next))
        case .pending:
            // Answered early: two taps is a hold, and starts one further in.
            show(index: 2)
        case .idle:
            if pickerVisible {
                emit(.closePicker)
                return
            }
            state = .pending(deadline: now().addingTimeInterval(Self.holdWindow))
            watch()
        }
    }

    /// From the HUD panel's `flagsChanged`, which is the fast path; the poll
    /// below is the safety net.
    public func modifiersChanged() {
        guard !isHoldingModifiers() else { return }
        switch state {
        case .pending:
            state = .idle
            emit(.openPicker)
        case .hud(let index):
            state = .idle
            emit(.paste(index: index))
        case .idle:
            break
        }
    }

    public func move(by delta: Int) {
        guard case .hud(let index) = state, clipCount() > 0 else { return }
        let count = clipCount()
        let next = ((index + delta) % count + count) % count
        state = .hud(index: next)
        emit(.selectHUD(index: next))
    }

    public func select(_ index: Int) {
        guard case .hud = state, index >= 0, index < clipCount() else { return }
        state = .hud(index: index)
        emit(.selectHUD(index: index))
    }

    /// A click on a card: choose it and paste it.
    public func commit(_ index: Int? = nil) {
        guard case .hud(let current) = state else { return }
        state = .idle
        emit(.paste(index: index ?? current))
    }

    public func cancel() {
        switch state {
        case .hud:
            state = .idle
            emit(.hideHUD)
        case .pending:
            state = .idle
        case .idle:
            break
        }
    }

    // MARK: - Watching the modifiers

    private func watch() {
        scheduler.run(after: Self.pollInterval) { [weak self] in
            guard let self else { return }
            switch self.state {
            case .pending(let deadline):
                if !self.isHoldingModifiers() {
                    self.state = .idle
                    self.emit(.openPicker)
                    return
                }
                if self.now() >= deadline {
                    self.show(index: 1)
                    return
                }
                self.watch()
            case .hud(let index):
                if !self.isHoldingModifiers() {
                    self.state = .idle
                    self.emit(.paste(index: index))
                    return
                }
                self.watch()
            case .idle:
                break
            }
        }
    }

    /// The HUD starts on the *second* clip: the first is what ⌘V already
    /// pastes, so stopping there would be a no-op.
    private func show(index: Int) {
        let count = clipCount()
        guard count > 0 else {
            state = .idle
            emit(.openPicker)
            return
        }
        let clamped = min(index, count - 1)
        state = .hud(index: clamped)
        emit(.showHUD(index: clamped))
        watch()
    }

    private func advance(from index: Int) -> Int {
        let count = max(1, clipCount())
        return (index + 1) % count
    }

    private func emit(_ event: Event) {
        onEvent(event)
    }
}
