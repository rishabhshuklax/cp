import XCTest
@testable import CpKit

final class SearchQueryTests: XCTestCase {

    private func clipping(
        kind: ClippingKind = .text,
        payload: String = "hello",
        app: String = "Xcode",
        bundle: String = "com.apple.dt.Xcode",
        pinned: Bool = false,
        bytes: Int = 100,
        age: TimeInterval = 0
    ) -> Clipping {
        Clipping(
            kind: kind,
            payload: payload,
            sourceBundleID: bundle,
            sourceAppName: app,
            createdAt: Date().addingTimeInterval(-age),
            isPinned: pinned,
            byteCount: bytes
        )
    }

    func testParsesAppFilter() {
        let query = SearchQuery.parse("app:xcode auth")
        XCTAssertEqual(query.filters, [.app("xcode")])
        XCTAssertEqual(query.text, "auth")
    }

    func testParsesTypeAliases() {
        XCTAssertEqual(SearchQuery.parse("type:link").filters, [.kind(.url)])
        XCTAssertEqual(SearchQuery.parse("type:img").filters, [.kind(.image)])
        XCTAssertEqual(SearchQuery.parse("type:code").filters, [.kind(.code)])
    }

    func testUnknownTokensStayAsSearchText() {
        let query = SearchQuery.parse("foo:bar baz")
        XCTAssertTrue(query.filters.isEmpty)
        XCTAssertEqual(query.text, "foo:bar baz")
    }

    func testParsesSizeFilter() {
        XCTAssertEqual(SearchQuery.parse(">1kb").filters, [.minBytes(1_024)])
        XCTAssertEqual(SearchQuery.parse(">2mb").filters, [.minBytes(2 * 1_024 * 1_024)])
    }

    func testAppFilterMatchesNameOrBundle() {
        let query = SearchQuery(filters: [.app("xcode")])
        XCTAssertTrue(query.passesFilters(clipping()))
        XCTAssertFalse(query.passesFilters(clipping(app: "Safari", bundle: "com.apple.Safari")))
    }

    func testPinnedFilter() {
        let query = SearchQuery(filters: [.pinnedOnly])
        XCTAssertTrue(query.passesFilters(clipping(pinned: true)))
        XCTAssertFalse(query.passesFilters(clipping(pinned: false)))
    }

    func testByteFormatParsing() {
        XCTAssertEqual(ByteFormat.parse("512"), 512)
        XCTAssertEqual(ByteFormat.parse("1k"), 1_024)
        XCTAssertEqual(ByteFormat.parse("1.5kb"), 1_536)
        XCTAssertNil(ByteFormat.parse("banana"))
    }
}
