import AppKit
import ApplicationServices
import SwiftUI

/// The formats a clipping could have been pasted as, offered where it landed.
///
/// This is the redesign's answer to "paste as…" menus: you do not have to know
/// in advance. Paste, see it, and if the link should have been Markdown, the
/// chip is right there under the caret — one click, and the paste is swapped in
/// place with ⌘Z rather than left for you to fix.
public struct FormatChipView: View {

    private let clipping: Clipping
    private let formats: [PasteFormat]
    private let selected: PasteFormat
    private let choose: (PasteFormat) -> Void

    public init(
        clipping: Clipping,
        formats: [PasteFormat],
        selected: PasteFormat,
        choose: @escaping (PasteFormat) -> Void
    ) {
        self.clipping = clipping
        self.formats = formats
        self.selected = selected
        self.choose = choose
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(formats, id: \.self) { format in
                let isOn = format == selected
                Button { choose(format) } label: {
                    Text(format.chipLabel(for: clipping))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isOn ? Theme.ink : Theme.ink2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(isOn ? Theme.selection : .clear,
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay {
                            if isOn {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(Theme.selectionEdge, lineWidth: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .cpGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(8)
        .environment(\.colorScheme, NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light)
    }
}

/// Where the chip goes, in order of how well each answer knows where the paste
/// actually landed.
public enum ChipPlacement {

    /// Below the caret when the app will say where it is, else at the foot of
    /// the window it went into, else by the pointer. Always on screen.
    public static func origin(
        chipSize: CGSize,
        caret: CGRect?,
        window: CGRect?,
        pointer: CGPoint,
        screen: CGRect,
        margin: CGFloat = 12
    ) -> CGPoint {
        var origin: CGPoint
        if let caret = usable(caret) {
            origin = CGPoint(x: caret.midX - chipSize.width / 2, y: caret.minY - chipSize.height - 2)
        } else if let window = usable(window) {
            origin = CGPoint(x: window.midX - chipSize.width / 2, y: window.minY + 24)
        } else {
            origin = CGPoint(x: pointer.x - chipSize.width / 2, y: pointer.y - chipSize.height - 18)
        }
        origin.x = min(max(origin.x, screen.minX + margin), screen.maxX - chipSize.width - margin)
        origin.y = min(max(origin.y, screen.minY + margin), screen.maxY - chipSize.height - margin)
        return origin
    }

    /// Chrome and Electron answer the caret question with an empty rect, and
    /// some apps answer it with nonsense; both mean "no idea".
    static func usable(_ rect: CGRect?) -> CGRect? {
        guard let rect, !rect.isNull, !rect.isInfinite,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0 || rect.height > 0 else { return nil }
        return rect
    }
}

/// Asks the system where the text caret is, and where the target's window is.
public enum CaretLocator {

    /// The caret's rectangle in screen coordinates, if the focused app will
    /// say. Accessibility only — the same grant pasting already needs.
    @MainActor
    public static func caretRect() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        // An unresponsive app must not take the chip down with it.
        AXUIElementSetMessagingTimeout(system, 0.2)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        let field = element as! AXUIElement

        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let selection = range, CFGetTypeID(selection) == AXValueGetTypeID() else { return nil }

        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            field, kAXBoundsForRangeParameterizedAttribute as CFString, selection, &bounds
        ) == .success, let value = bounds, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        guard let usable = ChipPlacement.usable(rect) else { return nil }
        return flipped(usable)
    }

    /// The frontmost ordinary window of an app, from the window list. Needs no
    /// permission: only the bounds are read, never a window's name.
    public static func windowRect(pid: pid_t) -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width > 80, height > 80 else { continue }
            return flipped(CGRect(x: x, y: y, width: width, height: height))
        }
        return nil
    }

    /// Accessibility and the window list both measure down from the top-left of
    /// the primary display; AppKit measures up from its bottom-left.
    static func flipped(_ rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        return CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// The chip's window: never key, never activating, gone in eight seconds.
@MainActor
public final class FormatChipWindow {

    private var panel: OverlayPanel?
    private var dismissal: Task<Void, Never>?
    private var clickMonitor: Any?
    private var activationObserver: NSObjectProtocol?

    /// How long a chip waits before it stops being useful and starts being
    /// clutter.
    public static let lifetime: TimeInterval = 8

    public init() {}

    public var isVisible: Bool { panel?.isVisible ?? false }

    public func show(
        clipping: Clipping,
        formats: [PasteFormat],
        selected: PasteFormat,
        target: NSRunningApplication?,
        choose: @escaping (PasteFormat) -> Void
    ) {
        guard formats.count > 1 else { return }
        let panel = existingOrNewPanel()
        let view = FormatChipView(clipping: clipping, formats: formats, selected: selected, choose: choose)
        let hosting = FirstMouseHostingView(rootView: view)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.setContentSize(size)

        let pointer = NSEvent.mouseLocation
        let screen = (NSWindow.activeScreen ?? NSScreen.main)?.visibleFrame ?? .zero
        let origin = ChipPlacement.origin(
            chipSize: size,
            caret: CaretLocator.caretRect(),
            window: target.map { CaretLocator.windowRect(pid: $0.processIdentifier) } ?? nil,
            pointer: pointer,
            screen: screen
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        watchForDismissal()
    }

    public func hide() {
        dismissal?.cancel()
        dismissal = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        panel?.orderOut(nil)
    }

    private func watchForDismissal() {
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.lifetime * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
        guard clickMonitor == nil else { return }
        // A click anywhere else means you have moved on. A global monitor sees
        // clicks without consuming them, and needs no permission.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func existingOrNewPanel() -> OverlayPanel {
        if let panel { return panel }
        let panel = OverlayPanel(rect: NSRect(x: 0, y: 0, width: 200, height: 40))
        self.panel = panel
        return panel
    }
}
