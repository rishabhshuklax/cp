import AppKit
import Carbon.HIToolbox
import XCTest
@testable import CpKit

@MainActor
final class SettingsSurfaceTests: XCTestCase {

    /// A shortcut has to carry a real modifier, or it fires while you type.
    func testTheRecorderOnlyAcceptsRealShortcuts() {
        let combo = HotKeyRecorder.combo(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command, .shift])
        XCTAssertEqual(combo, HotKeyCombo(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey)))
        XCTAssertEqual(combo?.displayString, "⇧⌘K")

        XCTAssertEqual(
            HotKeyRecorder.combo(keyCode: UInt16(kVK_Space), modifiers: [.control, .option])?.displayString,
            "⌃⌥Space"
        )
        XCTAssertNil(HotKeyRecorder.combo(keyCode: UInt16(kVK_ANSI_K), modifiers: []), "a bare key is not a shortcut")
        XCTAssertNil(HotKeyRecorder.combo(keyCode: UInt16(kVK_ANSI_K), modifiers: [.shift]), "⇧K is typing")
        XCTAssertNil(HotKeyRecorder.combo(keyCode: UInt16(kVK_Escape), modifiers: [.command]), "esc is the way out")

        // Caps lock and the function key are along for the ride, not part of it.
        XCTAssertEqual(
            HotKeyRecorder.combo(keyCode: UInt16(kVK_ANSI_V), modifiers: [.command, .shift, .capsLock, .function]),
            HotKeyCombo.shiftCommandV
        )
    }

    func testClipboardAccessLabels() {
        XCTAssertEqual(ClipboardAccess.allowed.label, "Allowed")
        XCTAssertEqual(ClipboardAccess.ask.label, "Ask each time")
        XCTAssertEqual(ClipboardAccess.notAllowed.label, "Not allowed")
    }

    /// The history row counts clips and bytes; passwords are in neither.
    func testHistorySummary() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.cp.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let settings = Settings(defaults: MemoryDefaults())
        let controller = AppController(settings: settings, archive: nil, pasteboard: pasteboard)
        controller.store.ingest(Clipping(kind: .text, payload: "one"))
        controller.store.ingest(Clipping(kind: .text, payload: "two"))
        controller.store.ingest(Clipping(kind: .text, payload: "", isConcealed: true), secret: "hunter2-hunter2")

        let summary = await controller.historySummary()
        XCTAssertEqual(summary, "2 clips", "no archive, so no size to report")
    }

    func testClearingHistoryKeepsPins() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.cp.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let settings = Settings(defaults: MemoryDefaults())
        let controller = AppController(settings: settings, archive: nil, pasteboard: pasteboard)
        controller.store.ingest(Clipping(kind: .text, payload: "ordinary"))
        let pinned = controller.store.ingest(Clipping(kind: .text, payload: "kept", isPinned: true))
        controller.stack.toggle(controller.store.clippings[0].id)

        controller.clearHistory()
        XCTAssertEqual(controller.store.clippings.map(\.id), [pinned.id])
        XCTAssertTrue(controller.stack.isEmpty, "the stack cannot hold clippings that are gone")
        XCTAssertEqual(controller.toasts.current?.text, "History cleared")
    }
}
