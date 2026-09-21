import AppKit
import SwiftUI

/// The window the picker lives in.
///
/// This is the one piece of the design that cannot be built in pure SwiftUI. A
/// `Window` scene either activates the app — stealing focus from whatever you were
/// about to paste into, which breaks the paste — or it can't take keyboard input at
/// all. The combination that works is an `NSPanel` with `.nonactivatingPanel` in
/// its style mask *and* `canBecomeKey` overridden to `true`: the panel takes key
/// events while the app underneath stays active, so ⌘V lands where you meant it.
///
/// Missing either half fails silently and differently — without the style mask the
/// app activates, without the override the arrow keys do nothing — which is why
/// this is spelled out here rather than left to be rediscovered.
public final class PickerPanel: NSPanel {

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // Above normal windows, below the menu bar and system alerts.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        isMovableByWindowBackground = false
        // Staying visible when the app deactivates is the whole point: the app you
        // are pasting into is, by definition, the active one.
        hidesOnDeactivate = false
        // No fade-in. This opens on a keystroke dozens of times a day.
        animationBehavior = .none

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
    }

    /// Without this the panel renders but never receives a key event, and every
    /// arrow key press goes to the app behind it.
    public override var canBecomeKey: Bool { true }

    /// Becoming *main* would mark the app as frontmost, which is exactly what
    /// `.nonactivatingPanel` is there to avoid.
    public override var canBecomeMain: Bool { false }

    /// Escape closes, matching every other transient panel on the platform.
    public override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    /// Centres on the screen holding the pointer — the one the user is looking at,
    /// which is not necessarily the one macOS calls `main`.
    public func positionOnActiveScreen() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let size = frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            // Slightly above centre. Dead-centre reads as low because the eye
            // treats the optical centre as a little above the geometric one.
            y: visible.midY - size.height / 2 + visible.height * 0.06
        )
        setFrameOrigin(origin)
    }
}
