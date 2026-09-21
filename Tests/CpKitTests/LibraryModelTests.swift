import AppKit
import XCTest
@testable import CpKit

@MainActor
final class LibraryModelTests: XCTestCase {

    private var settings: Settings!
    private var store: ClippingStore!
    private var model: LibraryModel!

    override func setUp() async throws {
        try await super.setUp()
        settings = Settings(defaults: MemoryDefaults())
        store = ClippingStore(archive: nil, settings: settings, recognizer: nil)
        model = LibraryModel(store: store, settings: settings,
                             links: LinkPreviews(store: store, settings: settings))
    }

    @discardableResult
    private func add(_ payload: String, kind: ClippingKind? = nil, app: String = "Notes",
                     bundle: String = "com.apple.Notes", age: TimeInterval = 0, pinned: Bool = false,
                     ocr: String? = nil, concealed: Bool = false) -> Clipping {
        let classified = Classifier.classify(payload)
        return store.ingest(
            Clipping(kind: kind ?? classified.kind, payload: concealed ? "" : payload,
                     sourceBundleID: bundle, sourceAppName: app,
                     createdAt: Date().addingTimeInterval(-age), isPinned: pinned,
                     isConcealed: concealed, detail: classified.detail, ocrText: ocr),
            secret: concealed ? payload : nil
        )
    }

    private func payloads(_ clippings: [Clipping]) -> [String] { clippings.map(\.payload) }

    // MARK: - What it shows

    func testPasswordsAreNeverShown() {
        add("a note")
        add("hunter2-hunter2", concealed: true)
        XCTAssertEqual(payloads(model.clippings), ["a note"])
        XCTAssertEqual(model.sidebarTop.first?.count, 1, "and they are not counted either")
    }

    func testTheSidebarFiltersAndCounts() {
        add("https://example.com/a", app: "Safari", bundle: "com.apple.Safari", age: 10)
        add("#FF5A36", app: "Figma", bundle: "com.figma.Desktop", age: 20)
        add("{\"a\":1}", age: 30)
        add("some prose", age: 40, pinned: true)
        add("func hello() {\n    print(\"hi\")\n}", age: 50)

        XCTAssertEqual(model.clippings.count, 5)
        XCTAssertEqual(model.sidebarTop.map(\.count), [5, 1])

        let kinds = model.sidebarKindItems
        XCTAssertEqual(kinds.map(\.title), ["Links", "Images", "Code", "Colours", "Files", "Text"])
        // Text holds prose, rich text and JSON: three wrappings of the same thing.
        XCTAssertEqual(kinds.first { $0.title == "Text" }?.count, 2)
        XCTAssertEqual(kinds.first { $0.title == "Links" }?.count, 1)

        model.filter = .kind(.text)
        XCTAssertEqual(Set(payloads(model.clippings)), ["some prose", "{\"a\":1}"])

        model.filter = .pinned
        XCTAssertEqual(payloads(model.clippings), ["some prose"])

        model.filter = .app(bundleID: "com.apple.Safari", name: "Safari")
        XCTAssertEqual(payloads(model.clippings), ["https://example.com/a"])
        XCTAssertEqual(model.filter.title, "Safari")

        XCTAssertEqual(model.sidebarApps.first?.title, "Notes", "most used first")
    }

    func testSearchReachesTextInsideImages() {
        add("a plain note", age: 10)
        add("Image 800×600", kind: .image, age: 20, ocr: "Invoice INV-2291 · Due 30 Sep")
        model.query = "invoice"
        XCTAssertEqual(model.clippings.count, 1)
        XCTAssertEqual(model.clippings.first?.kind, .image)
    }

    func testGroupsAreDaysInOrder() {
        add("today", age: 60)
        add("yesterday", age: 26 * 3_600)
        add("last week", age: 6 * 86_400)
        XCTAssertEqual(model.groups.map(\.day.rawValue), ["Today", "Yesterday", "Earlier"])
        XCTAssertEqual(model.groups.map(\.clippings.count), [1, 1, 1])
    }

    // MARK: - Selection

    func testSelectionAndFocus() {
        let first = add("one", age: 30)
        let second = add("two", age: 20)
        let third = add("three", age: 10)

        XCTAssertEqual(model.focus?.id, third.id, "with nothing picked, the newest")

        model.select(first.id, extending: false)
        XCTAssertEqual(model.selection, [first.id])
        XCTAssertEqual(model.focus?.id, first.id)

        model.select(second.id, extending: true)
        XCTAssertEqual(model.selection, [first.id, second.id])
        XCTAssertEqual(model.focus?.id, second.id, "the inspector follows the last one clicked")

        model.select(first.id, extending: true)
        XCTAssertEqual(model.selection, [second.id], "⌘-clicking a selected tile takes it out")

        model.select(third.id, extending: false)
        XCTAssertEqual(model.selection, [third.id], "a plain click replaces")

        model.filter = .pinned
        XCTAssertTrue(model.selection.isEmpty, "a new filter starts fresh")
    }

    func testTileShapePerKind() {
        let colour = add("#FF5A36", age: 10)
        let image = add("Image 8×6", kind: .image, age: 20)
        let link = add("https://example.com/a", age: 30)
        XCTAssertEqual(model.height(for: colour), 96)
        XCTAssertEqual(model.height(for: image), 150)
        XCTAssertGreaterThanOrEqual(model.height(for: link), 112)
        XCTAssertFalse(model.showsFooter(colour), "a colour says where it came from by being the colour")
        XCTAssertFalse(model.showsFooter(image))
        XCTAssertTrue(model.showsFooter(link))
    }

    func testKeptUntil() {
        let pinned = add("kept", pinned: true)
        let ordinary = add("ordinary")
        XCTAssertEqual(model.keptUntil(pinned), "You unpin it")
        XCTAssertEqual(model.keptUntil(ordinary), "History fills up")
    }

    /// The old browser never showed a copy made while it was open.
    func testItFollowsTheStore() {
        add("first", age: 10)
        XCTAssertEqual(model.clippings.count, 1)
        add("second", age: 5)
        XCTAssertEqual(payloads(model.clippings), ["second", "first"])
    }
}
