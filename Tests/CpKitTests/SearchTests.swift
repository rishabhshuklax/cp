import XCTest
@testable import CpKit

@MainActor
final class SearchTests: XCTestCase {

    private var settings: Settings!
    private var store: ClippingStore!
    private let now = Date()

    override func setUp() async throws {
        try await super.setUp()
        settings = Settings(defaults: MemoryDefaults())
        store = ClippingStore(archive: nil, settings: settings, recognizer: nil)
    }

    @discardableResult
    private func add(
        _ payload: String,
        kind: ClippingKind? = nil,
        app: String = "Notes",
        bundle: String = "com.apple.Notes",
        age: TimeInterval = 0,
        pinned: Bool = false,
        copies: Int = 1,
        linkTitle: String? = nil,
        ocr: String? = nil
    ) -> Clipping {
        let classified = Classifier.classify(payload)
        let clipping = Clipping(
            kind: kind ?? classified.kind, payload: payload, sourceBundleID: bundle, sourceAppName: app,
            createdAt: now.addingTimeInterval(-age), copyCount: copies, isPinned: pinned,
            detail: classified.detail, ocrText: ocr, linkTitle: linkTitle
        )
        return store.ingest(clipping)
    }

    private func texts(_ hits: [ClipHit]) -> [String] { hits.map(\.clipping.payload) }

    private func highlighted(_ hit: ClipHit) -> [String] {
        hit.titleRanges.map { (hit.clipping.displayTitle as NSString).substring(with: $0) }
    }

    // MARK: - Order

    /// Empty text is strict recency: no pins first, no copy-count or app nudges.
    func testEmptyTextIsStrictRecency() {
        add("oldest", age: 300, copies: 9)
        add("pinned in the middle", age: 200, pinned: true)
        add("newest", age: 10)
        add("middle", app: "Xcode", bundle: "com.apple.dt.Xcode", age: 100)
        XCTAssertEqual(texts(store.search(ClipQuery())), ["newest", "middle", "pinned in the middle", "oldest"])
        XCTAssertEqual(store.clippings.map(\.payload), ["newest", "middle", "pinned in the middle", "oldest"])
        XCTAssertTrue(store.search(ClipQuery(text: "   ")).allSatisfy { $0.score == 0 && $0.titleRanges.isEmpty })
    }

    func testPinnedScope() {
        add("a", age: 30, pinned: true)
        add("b", age: 20)
        add("c", age: 10, pinned: true)
        XCTAssertEqual(texts(store.search(ClipQuery(scope: .pinned))), ["c", "a"])
        XCTAssertEqual(texts(store.search(ClipQuery(text: "a", scope: .pinned))), ["a"])
    }

    // MARK: - Matching

    /// Fuzzy subsequence matching returned rows that never contained
    /// the word ("api" matched 1,208 rows, 84% without "api" in them).
    func testWordsMustAppearLiterally() {
        add("a pretty important note")      // a…p…i, but not "api"
        add("call the api tomorrow")
        add("API keys rotate on Friday")
        XCTAssertEqual(Set(texts(store.search(ClipQuery(text: "api")))), ["call the api tomorrow", "API keys rotate on Friday"])
        XCTAssertEqual(texts(store.search(ClipQuery(text: "api friday"))), ["API keys rotate on Friday"])
        XCTAssertTrue(store.search(ClipQuery(text: "api zebra")).isEmpty)
    }

    func testMatchingIgnoresCaseAndAccents() {
        add("Meet at the Café Crème")
        add("ÉCOLE normale")
        add("cafe\u{301} decomposed")
        XCTAssertEqual(store.search(ClipQuery(text: "cafe")).count, 2)
        XCTAssertEqual(store.search(ClipQuery(text: "CRÈME")).count, 1)
        XCTAssertEqual(texts(store.search(ClipQuery(text: "ecole"))), ["ÉCOLE normale"])
    }

    /// The first build drew highlight offsets from the trimmed title onto the
    /// untrimmed preview, so "json" lit up "the ".
    func testHighlightsLandOnTheTypedLetters() throws {
        add("    Please update the json config before friday")
        let hit = try XCTUnwrap(store.search(ClipQuery(text: "json")).first)
        XCTAssertEqual(hit.clipping.displayTitle, "Please update the json config before friday")
        XCTAssertEqual(highlighted(hit), ["json"])

        add("🎉 Crème brûlée recipe — JSON export")
        let accented = try XCTUnwrap(store.search(ClipQuery(text: "creme json")).first)
        XCTAssertEqual(highlighted(accented), ["Crème", "JSON"])

        add("e\u{301}cole decomposed")
        let decomposed = try XCTUnwrap(store.search(ClipQuery(text: "ecole")).first)
        XCTAssertEqual(highlighted(decomposed), ["e\u{301}cole"])
    }

    func testTitleWordStartsOutrankOtherMatches() {
        add("the title says nothing\nfix it in the body", age: 10)   // body only
        add("prefix and suffix", age: 20)                           // inside a word in the title
        add("fix the flaky test", age: 30)                          // a word start in the title
        add("unrelated", app: "Fixer", bundle: "dev.fixer", age: 5) // the app name only
        let hits = store.search(ClipQuery(text: "fix"))
        XCTAssertEqual(texts(hits), [
            "fix the flaky test", "prefix and suffix", "the title says nothing\nfix it in the body", "unrelated",
        ])
        XCTAssertEqual(hits.map(\.field), [.title, .title, .body, .app])
        XCTAssertEqual(highlighted(hits[1]), ["fix", "fix"])
    }

    func testScoresByField() {
        add("fix the flaky test", age: 3 * 86_400 * 7)
        add("prefix only", age: 3 * 86_400 * 7)
        add("see below\nthe fix is here", age: 3 * 86_400 * 7)
        add("nothing", app: "Fixer", bundle: "dev.fixer", age: 3 * 86_400 * 7)
        let scores = Dictionary(uniqueKeysWithValues: store.search(ClipQuery(text: "fix")).map { ($0.clipping.payload, $0.score) })
        XCTAssertEqual(scores["fix the flaky test"], 30)
        XCTAssertEqual(scores["prefix only"], 20)
        XCTAssertEqual(scores["see below\nthe fix is here"], 10)
        XCTAssertEqual(scores["nothing"], 6)
    }

    func testRecencyBreaksTies() {
        add("deploy notes old", age: 30 * 86_400)
        add("deploy notes new", age: 60)
        XCTAssertEqual(texts(store.search(ClipQuery(text: "deploy"))), ["deploy notes new", "deploy notes old"])
    }

    // MARK: - Snippets and fields

    func testBodySnippetIsTheMatchingLine() throws {
        let body = "Release checklist\nbump the version\n" + String(repeating: "filler ", count: 40)
            + "then rotate the signing certificate before tagging and publishing the notes to the team channel\nend"
        add(body)
        let hit = try XCTUnwrap(store.search(ClipQuery(text: "certificate")).first)
        XCTAssertEqual(hit.field, .body)
        let snippet = try XCTUnwrap(hit.snippet)
        XCTAssertLessThanOrEqual(snippet.count, 120)
        XCTAssertFalse(snippet.contains("\n"))
        XCTAssertTrue(snippet.hasPrefix("…"), snippet)
        XCTAssertEqual(hit.snippetRanges.map { (snippet as NSString).substring(with: $0) }, ["certificate"])
        XCTAssertTrue(hit.titleRanges.isEmpty)

        let short = try XCTUnwrap(store.search(ClipQuery(text: "version")).first)
        XCTAssertEqual(short.snippet, "bump the version")
        XCTAssertEqual(short.snippetRanges, [NSRange(location: 9, length: 7)])
    }

    func testImageTextLinkPathAndAppFields() throws {
        add("Image 1440×900", kind: .image, ocr: "Invoice INV-2291\nDue 30 Sep 2026 · Total €48.20")
        add("https://www.figma.com/design/Qp2kT/cp-picker?node-id=12-4", linkTitle: "cp — Picker explorations")
        add("/Users/dev/Projects/worrier/Sources/Scarpines.swift")
        add("hello", app: "Ghostty", bundle: "com.mitchellh.ghostty")

        let invoice = try XCTUnwrap(store.search(ClipQuery(text: "total 48")).first)
        XCTAssertEqual(invoice.field, .imageText)
        XCTAssertEqual(invoice.snippet, "Due 30 Sep 2026 · Total €48.20")
        XCTAssertEqual(invoice.snippetRanges.map { (invoice.snippet! as NSString).substring(with: $0) }, ["Total", "48"])

        let link = try XCTUnwrap(store.search(ClipQuery(text: "figma")).first)
        XCTAssertEqual(link.field, .link)
        XCTAssertEqual(link.clipping.displayTitle, "cp — Picker explorations")
        let byTitle = try XCTUnwrap(store.search(ClipQuery(text: "picker")).first)
        XCTAssertEqual(byTitle.field, .title)

        let path = try XCTUnwrap(store.search(ClipQuery(text: "worrier")).first)
        XCTAssertEqual(path.field, .path)
        XCTAssertEqual(path.clipping.displayTitle, "Scarpines.swift")

        let app = try XCTUnwrap(store.search(ClipQuery(text: "ghost")).first)
        XCTAssertEqual(app.field, .app)
        XCTAssertNil(app.snippet)
    }

    func testIndexFollowsUpdates() throws {
        let link = add("https://example.com/p/123")
        XCTAssertTrue(store.search(ClipQuery(text: "quarterly")).isEmpty)
        var titled = link
        titled.linkTitle = "Quarterly report"
        store.update(titled)
        let hit = try XCTUnwrap(store.search(ClipQuery(text: "quarterly")).first)
        XCTAssertEqual(highlighted(hit), ["Quarterly"])
    }

    // MARK: - Filters

    func testFilters() {
        add("https://github.com/a/b", age: Ago.today)
        add("#FF5733", app: "Figma", bundle: "com.figma.Desktop", age: Ago.today / 2)
        add("Image 10×10", kind: .image, age: Ago.yesterday)
        add("plain words", age: 3 * 86_400, pinned: true)
        add("styled words", kind: .richText, age: 10 * 86_400)

        func payloads(_ filters: [ClipFilter]) -> Set<String> {
            Set(texts(store.search(ClipQuery(filters: filters))))
        }
        XCTAssertEqual(payloads([.kind(.url)]), ["https://github.com/a/b"])
        XCTAssertEqual(payloads([.kind(.url), .kind(.image)]), ["https://github.com/a/b", "Image 10×10"], "same sort: or")
        XCTAssertEqual(payloads([.kind(.text)]), ["plain words", "styled words"], "text includes rich text")
        XCTAssertEqual(payloads([.app(bundleID: "com.figma.Desktop", name: "Figma")]), ["#FF5733"])
        XCTAssertEqual(payloads([.kind(.color), .app(bundleID: "com.apple.Notes", name: "Notes")]), [], "different sorts: and")
        XCTAssertEqual(payloads([.day(.yesterday)]), ["Image 10×10"])
        XCTAssertTrue(payloads([.day(.today)]).isSuperset(of: ["https://github.com/a/b", "#FF5733"]))
        XCTAssertFalse(payloads([.day(.thisWeek)]).contains("styled words"))
        XCTAssertEqual(payloads([.pinned]), ["plain words"])
        XCTAssertEqual(texts(store.search(ClipQuery(text: "words", filters: [.kind(.richText)]))), ["styled words"])
    }

    func testFilterLabels() {
        XCTAssertEqual(ClipFilter.kind(.url).label, "Links")
        XCTAssertEqual(ClipFilter.app(bundleID: "com.figma.Desktop", name: "Figma").label, "From Figma")
        XCTAssertEqual(ClipFilter.day(.yesterday).label, "Yesterday")
        XCTAssertEqual(ClipFilter.day(.thisWeek).label, "This week")
        XCTAssertEqual(ClipFilter.pinned.label, "Pinned")
        XCTAssertFalse(ClipFilter.pinned.symbolName.isEmpty)
    }

    // MARK: - Suggestions

    func testSuggestionsForTheLastWord() {
        add("#FF5733", app: "Figma", bundle: "com.figma.Desktop")
        add("x", app: "Google Chrome", bundle: "com.google.Chrome")
        XCTAssertEqual(store.suggestion(for: "links"), .kind(.url))
        XCTAssertEqual(store.suggestion(for: "that invoice screenshots"), .kind(.image))
        XCTAssertEqual(store.suggestion(for: "Colours"), .kind(.color))
        XCTAssertEqual(store.suggestion(for: "colors"), .kind(.color))
        XCTAssertEqual(store.suggestion(for: "json"), .kind(.json))
        XCTAssertEqual(store.suggestion(for: "yesterday"), .day(.yesterday))
        XCTAssertEqual(store.suggestion(for: "api week"), .day(.thisWeek))
        XCTAssertEqual(store.suggestion(for: "fig"), .app(bundleID: "com.figma.Desktop", name: "Figma"))
        XCTAssertEqual(store.suggestion(for: "chr"), .app(bundleID: "com.google.Chrome", name: "Google Chrome"))
        XCTAssertNil(store.suggestion(for: "fi"), "three letters before an app is offered")
        XCTAssertNil(store.suggestion(for: "links "), "a finished word is left alone")
        XCTAssertNil(store.suggestion(for: "slack"), "only apps present in history")
        XCTAssertNil(store.suggestion(for: ""))
    }

    func testSourceAppsMostUsedFirst() {
        add("a", app: "Safari", bundle: "com.apple.Safari")
        add("b", app: "Xcode", bundle: "com.apple.dt.Xcode")
        add("c", app: "Xcode", bundle: "com.apple.dt.Xcode")
        XCTAssertEqual(store.sourceApps.map(\.name), ["Xcode", "Safari"])
        XCTAssertEqual(store.sourceApps.first?.count, 2)
    }

    // MARK: - Performance

    /// A keystroke cost 52 ms at 2,000 clippings in a release build. The
    /// target is under 8 ms in release; this runs in debug, so it only guards
    /// against the old order of magnitude and prints the real number.
    func testSearchSpeedOnTwoThousandClippings() {
        let words = ["deploy", "config", "error", "the", "json", "api", "swift", "invoice", "retry", "cache",
                     "window", "paste", "screen", "token", "build", "release", "network", "user", "query", "value"]
        var generator = SystemRandomNumberGenerator()
        for index in 0..<2_000 {
            let sentence = (0..<Int.random(in: 6...40, using: &generator))
                .map { _ in words.randomElement(using: &generator)! }
                .joined(separator: " ")
            let body = index % 50 == 0 ? String(repeating: sentence + "\n", count: 400) : sentence
            store.ingest(Clipping(kind: .text, payload: body, sourceBundleID: "com.apple.Notes", sourceAppName: "Notes",
                                  createdAt: now.addingTimeInterval(-Double(index) * 60)))
        }
        _ = store.search(ClipQuery(text: "warm"))   // builds the folded index once

        var times: [Double] = []
        for query in ["t", "th", "the", "a", "ap", "api", "j", "js", "jso", "json", "inv", "invoice retry"] {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = store.search(ClipQuery(text: query))
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        let median = times.sorted()[times.count / 2]
        print("search over 2,000 clippings (debug build): median \(String(format: "%.1f", median)) ms, max \(String(format: "%.1f", times.max()!)) ms")
        XCTAssertLessThan(median, 150)
    }
}
