import AppKit
import XCTest
@testable import CpKit

/// A paster that records instead of touching a pasteboard or pressing keys.
@MainActor
final class FakePaster: PasteWriting {
    var canPaste = true
    var writes: [PastePayload] = []
    var pastes: [String] = []
    var replacements: [PastePayload] = []
    var permissionRequests = 0
    private var changeCount = 100

    func requestPermission() { permissionRequests += 1 }

    @discardableResult
    func write(_ payload: PastePayload) -> Int {
        writes.append(payload)
        changeCount += 1
        return changeCount
    }

    func paste(into target: NSRunningApplication?, automatic: Bool, completion: @escaping @MainActor (PasteOutcome) -> Void) {
        pastes.append(target?.localizedName ?? "target")
        completion(automatic && canPaste ? .pasted(appName: target?.localizedName) : .copiedOnly(.notAllowed))
    }

    func replaceLastPaste(with payload: PastePayload, in target: NSRunningApplication?, completion: @escaping @MainActor (PasteOutcome) -> Void) {
        replacements.append(payload)
        write(payload)
        completion(.pasted(appName: target?.localizedName))
    }

    var strings: [String] { writes.compactMap(\.string) }
}

@MainActor
final class FakeStackHotKey: StackHotKeyRegistering {
    var handler: (() -> Void)?
    var log: [String] = []
    var isRegistered = false

    @discardableResult
    func register(_ handler: @escaping () -> Void) -> Bool {
        self.handler = handler
        isRegistered = true
        log.append("register")
        return true
    }

    func unregister() {
        isRegistered = false
        log.append("unregister")
    }

    /// One press of ⌘V.
    func press() { handler?() }
}

/// Runs the gap between pastes immediately, so a test can watch the order
/// without waiting for it.
struct ImmediateScheduler: Scheduling {
    func run(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        MainActor.assumeIsolated { work() }
    }
}

/// Holds the gap open until a test says go.
@MainActor
final class ManualScheduler: Scheduling {
    nonisolated init() {}
    private var pending: [() -> Void] = []
    var delays: [TimeInterval] = []

    nonisolated func run(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        MainActor.assumeIsolated {
            delays.append(delay)
            pending.append { work() }
        }
    }

    func fire() {
        let work = pending
        pending = []
        work.forEach { $0() }
    }
}

@MainActor
final class PasteStackTests: XCTestCase {

    private var settings: Settings!
    private var store: ClippingStore!
    private var paster: FakePaster!
    private var hotKey: FakeStackHotKey!
    private var ignored: [Int] = []
    private var toasts: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        settings = Settings(defaults: MemoryDefaults())
        store = ClippingStore(archive: nil, settings: settings, recognizer: nil)
        paster = FakePaster()
        hotKey = FakeStackHotKey()
        ignored = []
        toasts = []
    }

    private func makeStack(_ scheduler: Scheduling = ImmediateScheduler()) -> PasteStack {
        let stack = PasteStack(store: store, settings: settings, paster: paster, hotKey: hotKey, scheduler: scheduler)
        stack.ignoreChange = { [weak self] in self?.ignored.append($0) }
        stack.toast = { [weak self] in self?.toasts.append($0) }
        stack.frontmostApp = { nil }
        return stack
    }

    @discardableResult
    private func add(_ payload: String, kind: ClippingKind? = nil, concealed: Bool = false) -> Clipping {
        let classified = Classifier.classify(payload)
        return store.ingest(
            Clipping(kind: kind ?? classified.kind, payload: concealed ? "" : payload,
                     isConcealed: concealed, detail: classified.detail),
            secret: concealed ? payload : nil
        )
    }

    // MARK: - Contents

    func testTogglingAndBadges() {
        let first = add("one")
        let second = add("two")
        let secret = add("hunter2-hunter2", concealed: true)
        let stack = makeStack()

        stack.toggle(first.id)
        stack.toggle(second.id)
        XCTAssertEqual(stack.count, 2)
        XCTAssertEqual(stack.position(of: first.id), 1)
        XCTAssertEqual(stack.position(of: second.id), 2)

        stack.toggle(first.id)
        XCTAssertEqual(stack.position(of: second.id), 1, "the badges renumber")
        XCTAssertNil(stack.position(of: first.id))

        stack.toggle(secret.id)
        XCTAssertEqual(stack.count, 1, "a password would be forgotten before its turn")

        stack.clear()
        XCTAssertTrue(stack.isEmpty)
    }

    // MARK: - Paste in order

    /// Text goes as one paste: three pastes of three lines would be three undo
    /// steps in the target.
    func testATextOnlyStackGoesAsOnePaste() {
        let stack = makeStack()
        ["first line", "second line", "third line"].forEach { stack.toggle(add($0).id) }
        stack.pasteInOrder(into: nil)

        XCTAssertEqual(paster.strings, ["first line\nsecond line\nthird line"])
        XCTAssertEqual(paster.pastes.count, 1)
        XCTAssertEqual(ignored.count, 1, "the monitor is told to skip our own write")
        XCTAssertEqual(toasts, ["Pasted 3 in order"])
        XCTAssertTrue(stack.isEmpty)
    }

    func testAMixedStackIsPastedOneAtATimeWithAGap() {
        let scheduler = ManualScheduler()
        let stack = makeStack(scheduler)
        let text = add("a note")
        let file = store.ingest(Clipping(kind: .file, payload: "/Users/me/a.txt", origin: .fileURLs))
        let json = add("{\"a\":1}")
        [text, file, json].forEach { stack.toggle($0.id) }

        stack.pasteInOrder(into: nil)
        XCTAssertEqual(paster.strings, ["a note"])
        scheduler.fire()
        XCTAssertEqual(paster.writes.count, 2)
        XCTAssertEqual(paster.writes[1].fileURLs?.map(\.path), ["/Users/me/a.txt"])
        scheduler.fire()
        XCTAssertEqual(paster.strings.last, "{\n  \"a\": 1\n}", "each clip still pastes in its own default format")
        scheduler.fire()

        XCTAssertEqual(paster.pastes.count, 3)
        XCTAssertEqual(scheduler.delays, [PasteStack.gap, PasteStack.gap, PasteStack.gap])
        XCTAssertEqual(toasts, ["Pasted 3 in order"])
    }

    // MARK: - Arming

    /// Closing the picker with a stack hands ⌘V to cp: each press writes the
    /// next clip, lets a real ⌘V through, and takes the key back.
    func testArmedStackPastesOnePerCommandV() {
        let stack = makeStack()
        ["one", "two"].forEach { stack.toggle(add($0).id) }

        stack.armIfNeeded()
        XCTAssertTrue(stack.isArmed)
        XCTAssertEqual(hotKey.log, ["register"])

        hotKey.press()
        XCTAssertEqual(paster.strings, ["one"])
        XCTAssertEqual(stack.count, 1)
        XCTAssertEqual(hotKey.log, ["register", "unregister", "register"],
                       "⌘V is let go of around our own ⌘V, then taken back")
        XCTAssertTrue(stack.isArmed)
        XCTAssertTrue(toasts.isEmpty)

        hotKey.press()
        XCTAssertEqual(paster.strings, ["one", "two"])
        XCTAssertFalse(stack.isArmed, "the last one gives ⌘V back for good")
        XCTAssertEqual(hotKey.log.last, "unregister")
        XCTAssertEqual(toasts, ["Stack pasted"])
        XCTAssertEqual(ignored.count, 2)
    }

    func testArmingNeedsPermissionAndClips() {
        let stack = makeStack()
        stack.armIfNeeded()
        XCTAssertFalse(stack.isArmed, "nothing to paste")

        stack.toggle(add("one").id)
        paster.canPaste = false
        stack.armIfNeeded()
        XCTAssertFalse(stack.isArmed, "swallowing ⌘V without being able to paste would leave no way to paste")

        paster.canPaste = true
        stack.armIfNeeded()
        XCTAssertTrue(stack.isArmed)
        stack.clear()
        XCTAssertFalse(stack.isArmed, "clearing the stack gives ⌘V back")
    }

    func testAClippingDeletedWhileStackedIsSkipped() {
        let stack = makeStack()
        let gone = add("gone")
        let kept = add("kept")
        [gone, kept].forEach { stack.toggle($0.id) }
        store.delete(gone.id)

        stack.armIfNeeded()
        hotKey.press()
        XCTAssertEqual(paster.strings, ["kept"], "a clipping deleted since it was stacked costs no keypress")
        XCTAssertEqual(toasts, ["Stack pasted"])
    }
}
