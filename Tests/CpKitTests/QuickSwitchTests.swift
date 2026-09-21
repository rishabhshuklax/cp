import AppKit
import XCTest
@testable import CpKit

/// A clock a test can move by hand.
@MainActor
final class FakeClock {
    private(set) var now = Date(timeIntervalSinceReferenceDate: 1_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@MainActor
final class QuickSwitchTests: XCTestCase {

    private var clock: FakeClock!
    private var scheduler: ManualScheduler!
    private var events: [QuickSwitch.Event] = []
    private var holding = false
    private var count = 8
    private var holdToSwitch = true

    private func makeSwitch() -> QuickSwitch {
        let quickSwitch = QuickSwitch(
            scheduler: scheduler,
            now: { [unowned self] in self.clock.now },
            isHoldingModifiers: { [unowned self] in self.holding },
            clipCount: { [unowned self] in self.count },
            holdToSwitch: { [unowned self] in self.holdToSwitch }
        )
        quickSwitch.handleEvents { [unowned self] in self.events.append($0) }
        return quickSwitch
    }

    override func setUp() async throws {
        try await super.setUp()
        clock = FakeClock()
        scheduler = ManualScheduler()
        events = []
        holding = false
        count = 8
        holdToSwitch = true
    }

    /// Tap: the modifiers are gone before the window is up, so it is the
    /// picker you wanted.
    func testTapOpensThePicker() {
        let quickSwitch = makeSwitch()
        holding = true
        quickSwitch.hotKeyPressed(pickerVisible: false)
        XCTAssertEqual(quickSwitch.state, .pending(deadline: clock.now.addingTimeInterval(QuickSwitch.holdWindow)))
        XCTAssertTrue(events.isEmpty, "nothing happens until we know which it was")

        holding = false
        scheduler.fire()
        XCTAssertEqual(events, [.openPicker])
        XCTAssertEqual(quickSwitch.state, .idle)
    }

    /// Hold: still down when the window closes, so it is the HUD — starting on
    /// the second clip, because ⌘V already pastes the first.
    func testHoldShowsTheHUDOnTheSecondClip() {
        let quickSwitch = makeSwitch()
        holding = true
        quickSwitch.hotKeyPressed(pickerVisible: false)

        clock.advance(0.1)
        scheduler.fire()
        XCTAssertTrue(events.isEmpty, "still inside the window")
        XCTAssertEqual(quickSwitch.state, .pending(deadline: clock.now.addingTimeInterval(QuickSwitch.holdWindow - 0.1)))

        clock.advance(0.2)
        scheduler.fire()
        XCTAssertEqual(events, [.showHUD(index: 1)])
        XCTAssertEqual(quickSwitch.state, .hud(index: 1))
    }

    func testASecondPressInsideTheWindowSkipsTheWaitAndAClip() {
        let quickSwitch = makeSwitch()
        holding = true
        quickSwitch.hotKeyPressed(pickerVisible: false)
        quickSwitch.hotKeyPressed(pickerVisible: false)
        XCTAssertEqual(events, [.showHUD(index: 2)], "two taps is a hold, one clip further in")
        XCTAssertEqual(quickSwitch.state, .hud(index: 2))
    }

    func testFurtherPressesAdvanceAndWrap() {
        count = 3
        let quickSwitch = makeSwitch()
        holding = true
        quickSwitch.hotKeyPressed(pickerVisible: false)
        clock.advance(QuickSwitch.holdWindow)
        scheduler.fire()

        quickSwitch.hotKeyPressed(pickerVisible: false)
        quickSwitch.hotKeyPressed(pickerVisible: false)
        XCTAssertEqual(events, [.showHUD(index: 1), .selectHUD(index: 2), .selectHUD(index: 0)])
    }

    func testArrowsMoveBothWaysAndWrap() {
        count = 3
        let quickSwitch = makeSwitch()
        holding = true
        quickSwitch.hotKeyPressed(pickerVisible: false)
        clock.advance(QuickSwitch.holdWindow)
        scheduler.fire()
        events = []

        quickSwitch.move(by: 1)
        quickSwitch.move(by: 1)
        quickSwitch.move(by: -1)
        XCTAssertEqual(events, [.selectHUD(index: 2), .selectHUD(index: 0), .selectHUD(index: 2)])
    }

    /// Letting go is the whole gesture: it pastes what is lifted.
    func testReleasePastesTheSelectedClip() {
        let quickSwitch = makeSwitch()
        holding = true
        quickSwitch.hotKeyPressed(pickerVisible: false)
        clock.advance(QuickSwitch.holdWindow)
        scheduler.fire()
        quickSwitch.hotKeyPressed(pickerVisible: false)
        events = []

        holding = false
        quickSwitch.modifiersChanged()
        XCTAssertEqual(events, [.paste(index: 2)])
        XCTAssertEqual(quickSwitch.state, .idle)
    }

    /// The panel can become key after the release that was meant to commit it,
    /// so the poll has to catch that too.
    func testTheReleaseIsCaughtByThePollAsWell() {
        let quickSwitch = makeSwitch()
        holding = true
        quickSwitch.hotKeyPressed(pickerVisible: false)
        clock.advance(QuickSwitch.holdWindow)
        scheduler.fire()
        events = []

        holding = false
        scheduler.fire()
        XCTAssertEqual(events, [.paste(index: 1)])
    }

    func testEscapeCancelsWithoutPasting() {
        let quickSwitch = makeSwitch()
        holding = true
        quickSwitch.hotKeyPressed(pickerVisible: false)
        clock.advance(QuickSwitch.holdWindow)
        scheduler.fire()
        events = []

        quickSwitch.cancel()
        XCTAssertEqual(events, [.hideHUD])
        XCTAssertEqual(quickSwitch.state, .idle)

        holding = false
        scheduler.fire()
        XCTAssertEqual(events, [.hideHUD], "the poll has stopped with it")
    }

    func testClickingACardPastesIt() {
        let quickSwitch = makeSwitch()
        holding = true
        quickSwitch.hotKeyPressed(pickerVisible: false)
        clock.advance(QuickSwitch.holdWindow)
        scheduler.fire()
        events = []

        quickSwitch.commit(4)
        XCTAssertEqual(events, [.paste(index: 4)])
    }

    func testTheShortcutClosesAnOpenPicker() {
        let quickSwitch = makeSwitch()
        quickSwitch.hotKeyPressed(pickerVisible: true)
        XCTAssertEqual(events, [.closePicker])
        XCTAssertEqual(quickSwitch.state, .idle)
    }

    func testWithHoldToSwitchOffTheShortcutOnlyToggles() {
        holdToSwitch = false
        holding = true
        let quickSwitch = makeSwitch()
        quickSwitch.hotKeyPressed(pickerVisible: false)
        quickSwitch.hotKeyPressed(pickerVisible: true)
        XCTAssertEqual(events, [.openPicker, .closePicker])
        XCTAssertEqual(quickSwitch.state, .idle, "no waiting, no HUD")
    }

    func testWithOneClipTheHUDStartsOnItAndWithNoneThePickerOpens() {
        count = 1
        let quickSwitch = makeSwitch()
        holding = true
        quickSwitch.hotKeyPressed(pickerVisible: false)
        clock.advance(QuickSwitch.holdWindow)
        scheduler.fire()
        XCTAssertEqual(events, [.showHUD(index: 0)], "there is no second clip to start on")

        count = 0
        events = []
        let empty = makeSwitch()
        holding = true
        empty.hotKeyPressed(pickerVisible: false)
        clock.advance(QuickSwitch.holdWindow)
        scheduler.fire()
        XCTAssertEqual(events, [.openPicker], "nothing to switch between")
    }
}
