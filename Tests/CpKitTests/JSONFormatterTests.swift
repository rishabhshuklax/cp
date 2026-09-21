import XCTest
@testable import CpKit

/// Fix 11: formatting JSON must change whitespace and nothing else.
final class JSONFormatterTests: XCTestCase {

    private let input = #"{"name":"cp","version":"1.0.0","price":10.10,"id":12345678901234567890,"z":{},"a":[1e5,-0.0,"\u00e9\n\"q\"",[]],"ok":true,"none":null}"#

    func testPrettyKeepsKeyOrderNumbersAndEscapes() {
        let expected = """
        {
          "name": "cp",
          "version": "1.0.0",
          "price": 10.10,
          "id": 12345678901234567890,
          "z": {},
          "a": [
            1e5,
            -0.0,
            "\\u00e9\\n\\"q\\"",
            []
          ],
          "ok": true,
          "none": null
        }
        """
        XCTAssertEqual(JSONFormatter.pretty(input), expected)
    }

    func testMinifiedIsTheExactInverse() {
        guard let pretty = JSONFormatter.pretty(input, indent: 4) else { return XCTFail("valid JSON") }
        XCTAssertTrue(pretty.contains("\n        1e5,"))
        XCTAssertEqual(JSONFormatter.minified(pretty), input)
        XCTAssertEqual(JSONFormatter.minified(" [ 1 , 2 ] "), "[1,2]")
        XCTAssertEqual(JSONFormatter.minified("{ \"a b\" : \" spaced value \" }"), "{\"a b\":\" spaced value \"}")
    }

    func testScalarsAndEmptyContainers() {
        XCTAssertEqual(JSONFormatter.pretty("[]"), "[]")
        XCTAssertEqual(JSONFormatter.pretty("{ }"), "{}")
        XCTAssertEqual(JSONFormatter.pretty(" 42 "), "42")
        XCTAssertEqual(JSONFormatter.pretty("[{}]"), "[\n  {}\n]")
    }

    func testInvalidJSONIsNil() {
        for bad in ["", "{", "[1,]", "{\"a\":1,}", "{'a': 1}", "[01]", "[1.]", "[.5]", "12ab", "[\"unterminated]",
                    "{\"a\" 1}", "[1] [2]", "[\"\\x\"]", "[\"tab\there\"]", "nul", "{\"a\":}"] {
            XCTAssertNil(JSONFormatter.pretty(bad), bad)
            XCTAssertNil(JSONFormatter.minified(bad), bad)
        }
    }

    func testDeepNestingDoesNotRecurse() {
        let deep = String(repeating: "[", count: 50_000) + String(repeating: "]", count: 50_000)
        XCTAssertEqual(JSONFormatter.minified(deep), deep)
    }
}
