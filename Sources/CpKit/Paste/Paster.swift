import AppKit
import ApplicationServices
import Foundation

/// Puts a clipping back on the pasteboard and, optionally, presses ⌘V for you.
///
/// Synthesising the keystroke needs Accessibility permission. When it isn't
/// granted the app degrades to copy-only rather than failing: the content is on
/// the pasteboard and ⌘V works, it just isn't automatic. Silently doing nothing
/// would be the worst of the three options.
@MainActor
public final class Paster {

    private let pasteboard: NSPasteboard
    private let archive: ClippingArchive?

    public init(pasteboard: NSPasteboard = .general, archive: ClippingArchive?) {
        self.pasteboard = pasteboard
        self.archive = archive
    }

    public var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Opens the system prompt that deep-links to Privacy & Security. Only call
    /// this in response to a user action — it is a modal interruption.
    public func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Writes the clipping to the pasteboard, restoring its original type where we
    /// still have the bytes for it.
    public func writeToPasteboard(_ clipping: Clipping, asPlainText: Bool = false) {
        pasteboard.clearContents()

        if !asPlainText,
           clipping.kind == .image,
           let filename = clipping.assetFilename,
           let archive,
           let data = try? Data(contentsOf: archive.assetURL(for: filename)),
           let image = NSImage(data: data) {
            pasteboard.writeObjects([image])
            return
        }

        if !asPlainText, clipping.kind == .file {
            let urls = clipping.payload
                .split(separator: "\n")
                .map { URL(fileURLWithPath: String($0)) }
            if !urls.isEmpty {
                pasteboard.writeObjects(urls as [NSURL])
                return
            }
        }

        pasteboard.setString(clipping.payload, forType: .string)
    }

    public func writeRawText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Synthesises ⌘V into whatever is frontmost. Returns false when Accessibility
    /// permission is missing, so the caller can tell the user why nothing happened.
    @discardableResult
    public func synthesizePaste() -> Bool {
        guard hasAccessibilityPermission else { return false }

        let commandV: CGKeyCode = 0x09  // kVK_ANSI_V
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }

        // Stop the user's own physical modifier keys from bleeding into the
        // synthetic event — a still-held ⇧ from the hotkey would turn this into
        // ⌘⇧V, which means something else entirely in most editors.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalPointingDeviceEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: commandV, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: commandV, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}
