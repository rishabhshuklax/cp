import XCTest
@testable import CpKit

final class TransformTests: XCTestCase {

    func testStripsTrackingParameters() {
        let input = "https://example.com/post?utm_source=twitter&utm_medium=social&id=42&fbclid=abc"
        let output = Transform.stripTrackingParameters.apply(input)
        XCTAssertTrue(output.contains("id=42"))
        XCTAssertFalse(output.contains("utm_source"))
        XCTAssertFalse(output.contains("utm_medium"))
        XCTAssertFalse(output.contains("fbclid"))
    }

    func testStripTrackingDropsQueryEntirelyWhenAllTracking() {
        let output = Transform.stripTrackingParameters.apply("https://example.com/p?utm_source=x")
        XCTAssertEqual(output, "https://example.com/p")
    }

    func testStripIndentationRemovesCommonPrefix() {
        let input = "        let a = 1\n        let b = 2\n"
        let output = Transform.stripIndentation.apply(input)
        XCTAssertEqual(output, "let a = 1\nlet b = 2\n")
    }

    func testStripIndentationIgnoresBlankLines() {
        let input = "    a\n\n    b"
        XCTAssertEqual(Transform.stripIndentation.apply(input), "a\n\nb")
    }

    func testJoinLines() {
        XCTAssertEqual(Transform.joinLines.apply("one\n  two  \n\nthree"), "one two three")
    }

    func testJSONRoundTrip() {
        let minified = "{\"b\":2,\"a\":1}"
        let pretty = Transform.prettyJSON.apply(minified)
        XCTAssertTrue(pretty.contains("\n"))
        // sortedKeys is on, so pretty-printing normalises the ordering.
        XCTAssertTrue(pretty.range(of: "\"a\"")!.lowerBound < pretty.range(of: "\"b\"")!.lowerBound)
        XCTAssertEqual(Transform.minifyJSON.apply(pretty), "{\"a\":1,\"b\":2}")
    }

    func testBasename() {
        let input = "/Users/me/a.txt\n/tmp/b.png"
        XCTAssertEqual(Transform.basename.apply(input), "a.txt\nb.png")
    }

    func testCatalogueIsKindSpecific() {
        let urlIDs = Transform.available(for: .url).map(\.id)
        XCTAssertTrue(urlIDs.contains("untrack"))
        XCTAssertFalse(urlIDs.contains("jsonPretty"))

        let jsonIDs = Transform.available(for: .json).map(\.id)
        XCTAssertTrue(jsonIDs.contains("jsonPretty"))

        // Images have no text to transform.
        XCTAssertTrue(Transform.available(for: .image).isEmpty)
    }

    func testTrimIsAlwaysOfferedForTextualKinds() {
        for kind in ClippingKind.allCases where kind != .image {
            XCTAssertTrue(
                Transform.available(for: kind).contains { $0.id == "trim" },
                "\(kind) should offer trim"
            )
        }
    }
}
