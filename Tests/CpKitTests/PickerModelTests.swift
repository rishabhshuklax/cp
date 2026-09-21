import AppKit
import Carbon.HIToolbox
import XCTest
@testable import CpKit

/// Records what the picker asked the app to do.
@MainActor
final class TestHost: PickerHost {
    var canPaste = true
    var pastes: [(clipping: Clipping, format: PasteFormat)] = []
    var events: [String] = []

    func paste(_ clipping: Clipping, as format: PasteFormat) {
        pastes.append((clipping, format))
        events.append("paste:\(clipping.title)")
    }
    func pasteStackInOrder() { events.append("pasteStack") }
    func closePicker() { events.append("close") }
    func openSettings() { events.append("settings") }
    func openLink(_ clipping: Clipping) { events.append("openLink") }
    func openSource(_ clipping: Clipping) { events.append("openSource") }
    func revealInFinder(_ clipping: Clipping) { events.append("reveal") }
    func saveImageToDesktop(_ clipping: Clipping) { events.append("save") }
    func togglePin(_ clipping: Clipping) { events.append("pin:\(clipping.title)") }
    func delete(_ clipping: Clipping) { events.append("delete:\(clipping.title)") }
    func forget(_ clipping: Clipping) { events.append("forget") }
    func undoDelete() { events.append("undo") }
    func requestPastePermission() { events.append("permission") }
}

@MainActor
final class PickerModelTests: XCTestCase {

    private var settings: Settings!
    private var store: ClippingStore!
    private var model: PickerModel!
    private var host: TestHost!
    private var stack: PasteStack!
    private let pointer = CGPoint(x: 100, y: 100)

    override func setUp() async throws {
        try await super.setUp()
        settings = Settings(defaults: MemoryDefaults())
        store = ClippingStore(archive: nil, settings: settings, recognizer: nil)
        stack = PasteStack(store: store, settings: settings, paster: FakePaster(),
                           hotKey: FakeStackHotKey(), scheduler: ImmediateScheduler())
        model = PickerModel(store: store, settings: settings,
                            links: LinkPreviews(store: store, settings: settings), stack: stack)
        host = TestHost()
        model.host = host
    }

    @discardableResult
    private func add(_ payload: String, kind: ClippingKind? = nil, app: String = "Notes",
                     bundle: String = "com.apple.Notes", age: TimeInterval = 0, pinned: Bool = false,
                     ocr: String? = nil, sourceURL: String? = nil) -> Clipping {
        let classified = Classifier.classify(payload)
        return store.ingest(Clipping(
            kind: kind ?? classified.kind, payload: payload, sourceBundleID: bundle, sourceAppName: app,
            createdAt: Date().addingTimeInterval(-age), isPinned: pinned, detail: classified.detail,
            ocrText: ocr, sourceURL: sourceURL
        ))
    }

    private func key(_ code: Int, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
            context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false,
            keyCode: UInt16(code)
        )!
    }

    // MARK: - Selection

    /// Opening selects the newest clip — what ⌘V would paste — and never a pin
    /// for being a pin. Preselecting a pin is what made the old picker paste
    /// something nobody had looked at.
    func testOpeningSelectsTheNewestClip() {
        add("oldest", age: 900)
        add("a pinned favourite", age: 600, pinned: true)
        let newest = add("the newest thing", age: 1)

        model.open(pointer: pointer)
        XCTAssertEqual(model.selectedID, newest.id)
        XCTAssertEqual(model.selected?.payload, "the newest thing")
        XCTAssertEqual(model.hits.count, 3)
    }

    func testEveryChangeOfQueryTokenOrScopeSelectsTheTopResult() {
        add("alpha note", age: 300)
        let beta = add("beta note", age: 200)
        add("newest", age: 1)
        model.open(pointer: pointer)

        model.query = "beta"
        XCTAssertEqual(model.selectedID, beta.id, "typing goes to the best match")

        model.query = ""
        XCTAssertEqual(model.selected?.payload, "newest")

        model.moveSelection(by: 2)
        XCTAssertEqual(model.selected?.payload, "alpha note")
        model.addToken(.kind(.text))
        XCTAssertEqual(model.selected?.payload, "newest", "a new token goes back to the top")

        model.moveSelection(by: 1)
        model.setScope(.pinned)
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertNil(model.selectedID)
    }

    /// A row sliding under a still pointer must not change the selection: that
    /// is how the old picker pasted row 12 after a click on row 4.
    func testThePointerOnlySelectsAfterItMoves() {
        add("one", age: 30)
        add("two", age: 20)
        let three = add("three", age: 10)
        model.open(pointer: pointer)
        XCTAssertEqual(model.selected?.payload, "three")

        let first = model.hits[1].id
        model.pointerMoved(to: pointer, over: first)
        XCTAssertEqual(model.selectedID, three.id, "same point: the list moved, the hand did not")

        model.pointerMoved(to: CGPoint(x: 100, y: 101), over: first)
        XCTAssertEqual(model.selectedID, first, "the pointer moved, so it selects")
    }

    /// Hover never scrolls, and the arrow keys only scroll when the selection
    /// has actually left the viewport.
    func testScrollingIsMinimal() {
        for index in 0..<30 { add("row \(index) note", age: TimeInterval(30 - index)) }
        model.open(pointer: pointer)
        // A query, so the list is 30 plain rows with no day labels in it.
        model.query = "note"
        XCTAssertEqual(model.hits.count, 30)
        // Rows 0…8 fit; row 9 runs off the bottom by 4pt.
        model.viewportChanged(top: 0, height: 380)

        model.handle(.down)
        XCTAssertNil(model.scrollTarget, "the second row of thirty is already on screen")

        for _ in 0..<7 { model.handle(.down) }
        XCTAssertNil(model.scrollTarget, "still inside the viewport")

        model.handle(.down)
        XCTAssertEqual(model.scrollTarget?.anchor, .bottom, "row 9 runs off the bottom")
        XCTAssertEqual(model.scrollTarget?.id, model.hits[9].id)

        // The view scrolls; the selection walks back up until it leaves the top.
        model.viewportChanged(top: 300, height: 380)
        let token = model.scrollTarget?.token
        model.handle(.up)
        XCTAssertEqual(model.scrollTarget?.token, token, "row 8 is visible: no scroll")
        model.handle(.up)
        XCTAssertEqual(model.scrollTarget?.anchor, .top)

        let target = model.scrollTarget
        model.pointerMoved(to: CGPoint(x: 1, y: 1), over: model.hits[20].id)
        XCTAssertEqual(model.selectedID, model.hits[20].id)
        XCTAssertEqual(model.scrollTarget, target, "hover moves the selection and never the list")
    }

    func testListLayoutAnchors() {
        let layout = ListLayout(itemHeights: Array(repeating: 38, count: 20), topPadding: 4, bottomPadding: 10)
        XCTAssertEqual(layout.offset(of: 0), 4)
        XCTAssertEqual(layout.offset(of: 3), 4 + 3 * 38)
        XCTAssertNil(layout.anchor(for: 3, viewportTop: 0, viewportHeight: 380))
        XCTAssertEqual(layout.anchor(for: 11, viewportTop: 0, viewportHeight: 380), .bottom)
        XCTAssertEqual(layout.anchor(for: 0, viewportTop: 100, viewportHeight: 380), .top)
        XCTAssertNil(layout.anchor(for: 5, viewportTop: 100, viewportHeight: 380))
    }

    func testSectionsOnlyWithoutAQuery() {
        add("today", age: Ago.today)
        add("last week", age: 6 * 86_400)
        model.open(pointer: pointer)
        XCTAssertEqual(model.items.compactMap { if case .section(let day) = $0 { return day.rawValue } else { return nil } },
                       ["Today", "Earlier"])

        model.query = "day"
        XCTAssertTrue(model.items.allSatisfy { $0.hit != nil }, "searching is ranked, so dates would hide the best match")
    }

    // MARK: - Keys

    func testKeyMap() {
        XCTAssertEqual(PickerKeys.key(keyCode: UInt16(kVK_DownArrow), modifiers: []), .down)
        XCTAssertEqual(PickerKeys.key(keyCode: UInt16(kVK_Return), modifiers: []), .paste)
        XCTAssertEqual(PickerKeys.key(keyCode: UInt16(kVK_Return), modifiers: [.option]), .pastePlain)
        XCTAssertEqual(PickerKeys.key(keyCode: UInt16(kVK_Return), modifiers: [.shift]), .stackToggle)
        XCTAssertEqual(PickerKeys.key(keyCode: UInt16(kVK_Return), modifiers: [.command]), .stackPaste)
        XCTAssertEqual(PickerKeys.key(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command]), .actions)
        XCTAssertEqual(PickerKeys.key(keyCode: UInt16(kVK_ANSI_Y), modifiers: [.command]), .look)
        XCTAssertEqual(PickerKeys.key(keyCode: UInt16(kVK_ANSI_P), modifiers: [.command]), .pin)
        XCTAssertEqual(PickerKeys.key(keyCode: UInt16(kVK_Delete), modifiers: [.command]), .delete)
        XCTAssertEqual(PickerKeys.key(keyCode: UInt16(kVK_Delete), modifiers: []), .backspace)
        XCTAssertEqual(PickerKeys.key(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command]), .undo)
        XCTAssertEqual(PickerKeys.key(keyCode: UInt16(kVK_ANSI_Comma), modifiers: [.command]), .settings)
        XCTAssertEqual(PickerKeys.key(keyCode: UInt16(kVK_ANSI_3), modifiers: [.command]), .row(3))
        XCTAssertEqual(PickerKeys.key(keyCode: UInt16(kVK_Space), modifiers: []), .space)
        // ⌥1 typed ¡ in the old build; now it is not a picker key at all.
        XCTAssertNil(PickerKeys.key(keyCode: UInt16(kVK_ANSI_1), modifiers: [.option]))
        XCTAssertNil(PickerKeys.key(keyCode: UInt16(kVK_ANSI_A), modifiers: []))
    }

    /// Real `NSEvent`s through the handler the panel installs.
    func testEventsThroughTheHandler() {
        add("first", age: 30)
        add("second", age: 20)
        let newest = add("third", age: 10)
        model.open(pointer: pointer)

        XCTAssertTrue(model.handle(key(kVK_DownArrow)))
        XCTAssertEqual(model.selected?.payload, "second")

        XCTAssertTrue(model.handle(key(kVK_Return, [.option])))
        XCTAssertEqual(host.pastes.last?.format, .plainText)

        XCTAssertTrue(model.handle(key(kVK_ANSI_1, [.command])))
        XCTAssertEqual(host.pastes.last?.clipping.id, newest.id, "⌘1 is the first row, not the selected one")

        XCTAssertFalse(model.handle(key(kVK_ANSI_A)), "letters go to the search field")
        XCTAssertFalse(model.handle(key(kVK_ANSI_1, [.option])), "⌥1 goes to the field too")

        XCTAssertTrue(model.handle(key(kVK_ANSI_Comma, [.command])))
        XCTAssertEqual(host.events.last, "settings")
    }

    func testSpaceAndBackspaceOnlyActWhenTheFieldIsEmpty() {
        add("something", age: 10)
        model.open(pointer: pointer)

        XCTAssertTrue(model.handle(.space))
        XCTAssertTrue(model.isLookOpen, "space on an empty field is Look")
        XCTAssertTrue(model.handle(.space))
        XCTAssertFalse(model.isLookOpen)

        model.query = "some"
        XCTAssertFalse(model.handle(.space), "now it is a space in the query")
        XCTAssertFalse(model.handle(.backspace), "and backspace deletes a letter")

        model.query = ""
        model.addToken(.kind(.text))
        XCTAssertTrue(model.handle(.backspace))
        XCTAssertTrue(model.tokens.isEmpty, "backspace on an empty field pops the last filter")
        XCTAssertFalse(model.handle(.backspace), "with no filters left it belongs to the field")
    }

    func testEscapeWalksBackOut() {
        add("something", age: 10)
        model.open(pointer: pointer)
        model.query = "some"
        model.addToken(.kind(.text))
        model.isLookOpen = true
        model.openActions()

        model.handle(.escape)
        XCTAssertFalse(model.isActionsOpen)
        model.handle(.escape)
        XCTAssertFalse(model.isLookOpen)
        model.handle(.escape)
        XCTAssertEqual(model.query, "")
        XCTAssertTrue(model.tokens.isEmpty)
        XCTAssertTrue(host.events.isEmpty, "nothing has closed yet")
        model.handle(.escape)
        XCTAssertEqual(host.events, ["close"])
    }

    func testTabTakesTheSuggestionThenTogglesScope() {
        add("https://example.com/a", age: 20)
        add("plain note", age: 10)
        model.open(pointer: pointer)

        model.query = "links"
        XCTAssertEqual(model.suggestion, .kind(.url))
        model.handle(.tab)
        XCTAssertEqual(model.tokens, [.kind(.url)])
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.hits.count, 1)

        model.removeToken(at: 0)
        model.handle(.tab)
        XCTAssertEqual(model.scope, .pinned, "with nothing to accept, Tab is the scope switch")
        model.handle(.tab)
        XCTAssertEqual(model.scope, .recent)
    }

    func testPinDeleteAndUndoGoToTheHost() {
        let clipping = add("something", age: 10)
        model.open(pointer: pointer)
        model.handle(.pin)
        model.handle(.delete)
        model.handle(.undo)
        XCTAssertEqual(host.events, ["pin:\(clipping.title)", "delete:\(clipping.title)", "undo"])
    }

    func testReturnPastesInTheDefaultFormatAndCommandReturnPastesTheStack() {
        let json = add("{\"a\":1}", age: 10)
        model.open(pointer: pointer)
        model.handle(.paste)
        XCTAssertEqual(host.pastes.last?.format, .jsonPretty, "JSON pastes formatted")

        model.handle(.stackPaste)
        XCTAssertEqual(host.events.last, "paste:\(json.title)", "an empty stack just pastes")

        model.handle(.stackToggle)
        XCTAssertEqual(stack.count, 1)
        model.handle(.stackPaste)
        XCTAssertEqual(host.events.last, "pasteStack")
    }

    // MARK: - Actions

    func testActionsPerKind() {
        let link = add("https://example.com/p?utm_source=x", age: 10, sourceURL: "https://news.example.com")
        let actions = PickerModel.actions(for: link, settings: settings, inStack: false)
        XCTAssertEqual(actions.first?.label, "Paste link")
        XCTAssertEqual(actions.first?.key, "↩")
        XCTAssertTrue(actions.contains { $0.label == "Paste without tracking" })
        XCTAssertTrue(actions.contains { $0.label == "Open in browser" })
        XCTAssertTrue(actions.contains { $0.label == "Open where you copied it" })
        XCTAssertTrue(actions.contains { $0.label == "Add to the stack" && $0.key == "⇧↩" })
        XCTAssertTrue(actions.contains { $0.label == "Pin" && $0.key == "⌘P" })
        XCTAssertTrue(actions.contains { $0.label == "Delete" && $0.isDanger })
        XCTAssertEqual(actions.first { $0.startsGroup }?.label, "Add to the stack")

        let image = Clipping(kind: .image, payload: "Image 800×600", assetFilename: "a.png", ocrText: "Invoice 2291")
        let imageActions = PickerModel.actions(for: image, settings: settings, inStack: true)
        XCTAssertEqual(imageActions.map(\.label).prefix(3),
                       ["Paste image", "Paste text from image", "Save to Desktop"])
        XCTAssertTrue(imageActions.contains { $0.label == "Take out of the stack" })

        let file = Clipping(kind: .file, payload: "/Users/me/notes.md", origin: .fileURLs)
        XCTAssertTrue(PickerModel.actions(for: file, settings: settings, inStack: false)
            .contains { $0.label == "Show in Finder" })

        let secret = Clipping(kind: .text, payload: "", isConcealed: true)
        let secretActions = PickerModel.actions(for: secret, settings: settings, inStack: false)
        XCTAssertEqual(secretActions.map(\.label), ["Paste password", "Forget now"])
    }

    func testActionsListFiltersAndRuns() {
        add("https://example.com/p", age: 10)
        model.open(pointer: pointer)
        model.openActions()
        XCTAssertTrue(model.isActionsOpen)

        model.actionQuery = "markdown"
        XCTAssertEqual(model.actions.map(\.label), ["Paste as Markdown link"])
        model.handleAction(.run)
        XCTAssertEqual(host.pastes.last?.format, .markdown)
        XCTAssertFalse(model.isActionsOpen, "running an action closes the list")

        model.openActions()
        model.handleAction(.down)
        XCTAssertEqual(model.actionIndex, 1)
        model.handleAction(.up)
        XCTAssertEqual(model.actionIndex, 0)
        model.handleAction(.close)
        XCTAssertFalse(model.isActionsOpen)
    }

    func testHeroCapsulePerKind() {
        func capsule(_ payload: String, kind: ClippingKind? = nil, ocr: String? = nil) -> String? {
            store = ClippingStore(archive: nil, settings: settings, recognizer: nil)
            model = PickerModel(store: store, settings: settings,
                                links: LinkPreviews(store: store, settings: settings), stack: stack)
            let classified = Classifier.classify(payload)
            store.ingest(Clipping(kind: kind ?? classified.kind, payload: payload,
                                  detail: classified.detail, ocrText: ocr))
            model.open(pointer: pointer)
            return model.heroAction?.label
        }
        XCTAssertEqual(capsule("https://example.com/a?utm_source=x"), "Clean link")
        XCTAssertEqual(capsule("https://example.com/a"), "Markdown")
        XCTAssertEqual(capsule("func hello() {\n    print(\"hi\")\n}"), "Code block")
        XCTAssertEqual(capsule("{\"a\":1}"), "One line")
        XCTAssertEqual(capsule("/Users/me/a.txt"), "Path")
        XCTAssertEqual(capsule("Image 8×6", kind: .image, ocr: "text in it"), "Paste text")
        XCTAssertNil(capsule("Image 8×6", kind: .image))
        XCTAssertNil(capsule("just some words"))
    }

    /// ⌘ held swaps every visible time for the key that pastes that row.
    func testCommandHeldShowsKeycaps() {
        add("one", age: 10)
        model.open(pointer: pointer)
        XCTAssertFalse(model.isCommandHeld)
        model.modifiersChanged([.command, .shift])
        XCTAssertTrue(model.isCommandHeld)
        model.modifiersChanged([])
        XCTAssertFalse(model.isCommandHeld)
    }

    /// A copy landing while the picker is open shows up without losing the
    /// selection — the old browser never saw new copies at all.
    func testTheListFollowsTheStore() {
        let first = add("first", age: 10)
        model.open(pointer: pointer)
        model.handle(.down)
        add("second", age: 5)
        XCTAssertTrue(waitUntil { self.model.hits.count == 2 })
        XCTAssertEqual(model.selectedID, first.id, "the selection stays on the clipping, not the row")
    }
}
