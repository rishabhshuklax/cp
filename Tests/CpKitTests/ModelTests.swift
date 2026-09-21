import XCTest
@testable import CpKit

final class ModelTests: XCTestCase {

    func testDedupeKeyIgnoresSourceAndTime() {
        let a = Clipping(kind: .text, payload: "same", sourceAppName: "Xcode")
        let b = Clipping(kind: .text, payload: "same", sourceAppName: "Safari")
        XCTAssertEqual(a.dedupeKey, b.dedupeKey)
    }

    func testDedupeKeySeparatesKinds() {
        let text = Clipping(kind: .text, payload: "#FFF")
        let color = Clipping(kind: .color, payload: "#FFF")
        XCTAssertNotEqual(text.dedupeKey, color.dedupeKey)
    }

    func testTitleLineSkipsLeadingBlanks() {
        let clipping = Clipping(kind: .code, payload: "\n\n   struct A {}\n")
        XCTAssertEqual(clipping.titleLine, "struct A {}")
    }

    func testTimeBucketing() {
        let now = Date()
        let recent = Clipping(kind: .text, payload: "a", createdAt: now.addingTimeInterval(-60))
        XCTAssertEqual(TimeBucket.bucket(for: recent, now: now), .now)

        let older = Clipping(kind: .text, payload: "b", createdAt: now.addingTimeInterval(-30 * 86_400))
        XCTAssertEqual(TimeBucket.bucket(for: older, now: now), .older)

        let pinned = Clipping(kind: .text, payload: "c", createdAt: now.addingTimeInterval(-30 * 86_400), isPinned: true)
        XCTAssertEqual(TimeBucket.bucket(for: pinned, now: now), .pinned)
    }

    func testRelativeStamps() {
        let now = Date()
        XCTAssertEqual(TimeBucket.relativeStamp(for: now.addingTimeInterval(-30), now: now), "now")
        XCTAssertEqual(TimeBucket.relativeStamp(for: now.addingTimeInterval(-120), now: now), "2m")
        XCTAssertEqual(TimeBucket.relativeStamp(for: now.addingTimeInterval(-7_200), now: now), "2h")
        XCTAssertEqual(TimeBucket.relativeStamp(for: now.addingTimeInterval(-2 * 86_400), now: now), "2d")
    }

    func testColorParserExpandsShorthand() {
        XCTAssertNotNil(ColorParser.color(from: "#abc"))
        XCTAssertNotNil(ColorParser.color(from: "#AABBCC"))
        XCTAssertNotNil(ColorParser.color(from: "rgb(255, 0, 0)"))
        XCTAssertNil(ColorParser.color(from: "not a colour"))
    }

    func testLinkResolverParsesTitle() {
        let html = "<html><head><title>  Hello &amp;\n  World  </title></head><body>x</body></html>"
        XCTAssertEqual(LinkResolver.parseTitle(from: html), "Hello & World")
    }

    func testLinkResolverHandlesTitleWithAttributes() {
        let html = "<title lang=\"en\">Page</title>"
        XCTAssertEqual(LinkResolver.parseTitle(from: html), "Page")
    }

    func testLinkResolverReturnsNilWithoutTitle() {
        XCTAssertNil(LinkResolver.parseTitle(from: "<html><body>no title</body></html>"))
    }
}
