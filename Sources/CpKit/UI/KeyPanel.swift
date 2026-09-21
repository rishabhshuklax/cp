import AppKit
import SwiftUI

/// The window every keyboard surface lives in.
///
/// Two things have to be true at once: the panel takes key events, and the app
/// you were about to paste into stays frontmost. `.nonactivatingPanel` plus
/// `canBecomeKey` overridden is the only combination that does both — miss
/// either half and it fails silently, differently.
///
/// The third thing is why `sendEvent` is overridden. A focused SwiftUI
/// `TextField` swallows keys before any SwiftUI key handler sees them: ⌥1 typed
/// `¡`, ⌫ and ⌘⌫ never fired. Routing every key through the window first means
/// the picker's keys are the picker's, and everything it does not claim still
/// reaches the field with focus intact. Returning true from `keyHandler` means
/// the field never sees that key.
///
/// Borderless rather than `.titled`: a titled panel keeps an invisible 32pt
/// title-bar band at the top that eats clicks meant for the search field.
public final class KeyPanel: NSPanel {

    public var keyHandler: ((NSEvent) -> Bool)?
    public var onResignKey: (() -> Void)?

    public init(rect: NSRect) {
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    public override var canBecomeKey: Bool { true }

    /// Becoming *main* would mark cp as frontmost, which is exactly what the
    /// non-activating style is there to avoid.
    public override var canBecomeMain: Bool { false }

    public override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown || event.type == .flagsChanged, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    public override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// A panel that shows something and never takes focus: the toast, and the format
/// chip. It still takes clicks — see `FirstMouseHostingView` — because the chip
/// is made of buttons.
public final class OverlayPanel: NSPanel {

    public init(rect: NSRect) {
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}

/// A hosting view that acts on the first click.
///
/// Without this, clicking a button in a window that is not key spends the click
/// on bringing the window forward — and these windows never come forward,
/// because they never become key.
public final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @MainActor public required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @MainActor public required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension NSWindow {

    /// The screen the pointer is on — the one the user is looking at, which is
    /// not necessarily the one macOS calls `main`.
    public static var activeScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    /// Centred horizontally, with its top a fraction of the way down the visible
    /// frame. Higher than centre, because a panel you summon should land where
    /// the eye already is.
    public func positionOnActiveScreen(topFraction: CGFloat) {
        guard let visible = Self.activeScreen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(
            x: (visible.midX - frame.width / 2).rounded(),
            y: (visible.maxY - visible.height * topFraction - frame.height).rounded()
        ))
    }

    /// Dead centre of the active screen, for the quick-switch HUD.
    public func centreOnActiveScreen() {
        guard let visible = Self.activeScreen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(
            x: (visible.midX - frame.width / 2).rounded(),
            y: (visible.midY - frame.height / 2).rounded()
        ))
    }

    /// Keeps a panel inside the screen it is nearest to, for surfaces placed
    /// against something else's geometry (the caret, a window, the pointer).
    public func clampToScreen(margin: CGFloat = 12) {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? Self.activeScreen
        guard let visible = screen?.visibleFrame else { return }
        var origin = frame.origin
        origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - frame.width - margin)
        origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - frame.height - margin)
        setFrameOrigin(origin)
    }
}
