import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

public enum CopyOnlyReason: Sendable, Equatable {
    /// Accessibility (or event-posting) permission is missing.
    case notAllowed
    /// Pasting automatically is turned off in Settings.
    case turnedOff
    /// The app to paste into quit or never came to the front.
    case targetGone
}

public enum PasteOutcome: Sendable, Equatable {
    case pasted(appName: String?)
    case copiedOnly(CopyOnlyReason)
}

/// Puts content on the pasteboard and, when it may, presses ⌘V for you.
///
/// Synthesising the keystroke needs Accessibility permission. Without it the
/// content is still on the pasteboard and ⌘V works; the outcome says why the
/// paste itself didn't happen, so the UI can say so instead of doing nothing.
@MainActor
public final class Paster {

    /// Marks every item cp writes, so the monitor can tell its own writes from
    /// the user's copies even when the change count alone is ambiguous.
    public static let ownPasteboardType = NSPasteboard.PasteboardType("dev.cp.clipboard.own")

    private let pasteboard: NSPasteboard
    /// Kept alive until the next write: the pasteboard asks it for TIFF only
    /// when an app wants TIFF.
    private var tiffProvider: TIFFProvider?

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var canPaste: Bool {
        AXIsProcessTrusted() && CGPreflightPostEventAccess()
    }

    /// Opens the system prompts. Only call this in response to a user action —
    /// it is a modal interruption.
    public func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestPostEventAccess()
    }

    // MARK: - Writing

    /// Replaces the pasteboard's contents and returns the change count they
    /// landed at — the number the monitor should ignore. It has to be read
    /// after writing: predicting "current + 1" beforehand was off by one, and
    /// every paste from cp was captured again as a new copy.
    @discardableResult
    public func write(_ payload: PastePayload) -> Int {
        var items: [NSPasteboardItem] = []
        tiffProvider = nil

        if let urls = payload.fileURLs, !urls.isEmpty {
            // One item per file, as Finder writes them. The paths go on as text
            // too, so a text field gets the path instead of nothing.
            for (index, url) in urls.enumerated() {
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                if index == 0 {
                    item.setString(payload.string ?? urls.map(\.path).joined(separator: "\n"), forType: .string)
                }
                items.append(item)
            }
        } else {
            let item = NSPasteboardItem()
            if let png = payload.png {
                item.setData(png, forType: .png)
                // Apps that only read TIFF get it on demand; converting a 5K
                // screenshot eagerly costs 20 MB and most of a second.
                let provider = TIFFProvider(png: png)
                item.setDataProvider(provider, forTypes: [.tiff])
                tiffProvider = provider
            }
            if let rtf = payload.rtf { item.setData(rtf, forType: .rtf) }
            if let string = payload.string { item.setString(string, forType: .string) }
            items.append(item)
        }

        for item in items {
            item.setString("1", forType: Self.ownPasteboardType)
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
        return pasteboard.changeCount
    }

    // MARK: - Pasting

    /// Presses ⌘V in `target`, once it is frontmost. Never presses it anywhere
    /// else: if the target does not come forward within half a second, the
    /// content stays on the pasteboard and the outcome says so.
    public func paste(
        into target: NSRunningApplication?,
        automatic: Bool,
        completion: @escaping @MainActor (PasteOutcome) -> Void
    ) {
        guard automatic else { return completion(.copiedOnly(.turnedOff)) }
        guard canPaste else { return completion(.copiedOnly(.notAllowed)) }
        whenFrontmost(target) { [weak self] ready in
            guard ready, let self else { return completion(.copiedOnly(.targetGone)) }
            self.pressCommand(CGKeyCode(kVK_ANSI_V))
            completion(.pasted(appName: target?.localizedName))
        }
    }

    /// Swaps the paste just made for another format: ⌘Z, write, ⌘V, with the
    /// same frontmost check. The new content lands on the pasteboard either way.
    public func replaceLastPaste(
        with payload: PastePayload,
        in target: NSRunningApplication?,
        completion: @escaping @MainActor (PasteOutcome) -> Void
    ) {
        guard canPaste else {
            write(payload)
            return completion(.copiedOnly(.notAllowed))
        }
        whenFrontmost(target) { [weak self] ready in
            guard let self else { return completion(.copiedOnly(.targetGone)) }
            guard ready else {
                self.write(payload)
                return completion(.copiedOnly(.targetGone))
            }
            self.pressCommand(CGKeyCode(kVK_ANSI_Z))
            self.write(payload)
            self.pressCommand(CGKeyCode(kVK_ANSI_V))
            completion(.pasted(appName: target?.localizedName))
        }
    }

    /// Activates `target` if needed, then checks every 20 ms for up to 500 ms
    /// whether it is frontmost. Always waits one tick, so a panel that was just
    /// ordered out has handed focus back before a key is pressed.
    private func whenFrontmost(_ target: NSRunningApplication?, then: @escaping @MainActor (Bool) -> Void) {
        guard let target, !target.isTerminated else { return then(false) }
        if !Self.isFrontmost(target) { target.activate() }
        Task { @MainActor in
            for _ in 0..<25 {
                try? await Task.sleep(nanoseconds: 20_000_000)
                if target.isTerminated { return then(false) }
                if Self.isFrontmost(target) { return then(true) }
            }
            then(false)
        }
    }

    private static func isFrontmost(_ app: NSRunningApplication) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    /// Posts ⌘ plus a key with every other modifier cleared.
    private func pressCommand(_ key: CGKeyCode) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        // Stop the user's own physical modifier keys from bleeding into the
        // synthetic event — a still-held ⇧ from the hotkey would turn this into
        // ⌘⇧V, which means something else entirely in most editors.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }
}

/// Converts PNG to TIFF when, and only when, the pasteboard asks.
private final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
    private let png: Data

    init(png: Data) {
        self.png = png
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff, let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation else { return }
        item.setData(tiff, forType: .tiff)
    }
}
