import Carbon.HIToolbox
import XCTest
@testable import CpKit

@MainActor
final class SettingsTests: XCTestCase {

    func testDefaults() {
        let settings = Settings(defaults: MemoryDefaults())
        XCTAssertEqual(settings.historyLimit, 2_000)
        XCTAssertTrue(settings.recognizeText)
        XCTAssertEqual(settings.secretLifetime, 60)
        XCTAssertTrue(settings.holdToSwitch)
        XCTAssertEqual(settings.hotKey, .shiftCommandV)
        XCTAssertFalse(settings.pasteRichAsPlain)
        XCTAssertFalse(settings.resolveLinkTitles)
        XCTAssertTrue(settings.ignoredBundleIDs.contains("com.agilebits.onepassword"))
    }

    func testValuesPersist() {
        let defaults = MemoryDefaults()
        let settings = Settings(defaults: defaults)
        settings.recognizeText = false
        settings.secretLifetime = 0
        settings.holdToSwitch = false
        settings.hotKey = HotKeyCombo(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey))
        settings.pasteRichAsPlain = true
        settings.historyLimit = 500

        let reloaded = Settings(defaults: defaults)
        XCTAssertFalse(reloaded.recognizeText)
        XCTAssertEqual(reloaded.secretLifetime, 0, "zero means never keep, not unset")
        XCTAssertFalse(reloaded.holdToSwitch)
        XCTAssertEqual(reloaded.hotKey.displayString, "⌃⌥K")
        XCTAssertTrue(reloaded.pasteRichAsPlain)
        XCTAssertEqual(reloaded.historyLimit, 500)
    }

    func testHotKeyDisplayString() {
        XCTAssertEqual(HotKeyCombo.shiftCommandV.displayString, "⇧⌘V")
        let all = HotKeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        XCTAssertEqual(all.displayString, "⌃⌥⇧⌘Space")
    }
}
