import XCTest
@testable import CpKit

final class ClassifierTests: XCTestCase {

    func testHexColors() {
        XCTAssertEqual(Classifier.classify("#FF5733").kind, .color)
        XCTAssertEqual(Classifier.classify("#abc").kind, .color)
        XCTAssertEqual(Classifier.classify("#AABBCCDD").kind, .color)
        XCTAssertEqual(Classifier.classify("#FF5733").detail, "#FF5733")
        // #RGBA is CSS Color 4 shorthand, and `ColorParser` expands it.
        XCTAssertEqual(Classifier.classify("#F57A").kind, .color)
        // Wrong digit count is not a colour.
        XCTAssertNotEqual(Classifier.classify("#FF573").kind, .color)
        XCTAssertNotEqual(Classifier.classify("#hello!").kind, .color)
    }

    func testFunctionalColors() {
        XCTAssertEqual(Classifier.classify("rgb(255, 87, 51)").kind, .color)
        XCTAssertEqual(Classifier.classify("rgba(0,0,0,0.5)").kind, .color)
        XCTAssertEqual(Classifier.classify("hsl(9, 100%, 60%)").kind, .color)
        // A CSS variable inside rgb() is not a literal colour.
        XCTAssertNotEqual(Classifier.classify("rgb(var(--brand))").kind, .color)
    }

    func testURLs() {
        let result = Classifier.classify("https://github.com/org/repo/pull/1234")
        XCTAssertEqual(result.kind, .url)
        XCTAssertEqual(result.detail, "github.com")

        XCTAssertEqual(Classifier.classify("www.example.com/path").kind, .url)
        // Prose containing a link is prose.
        XCTAssertEqual(Classifier.classify("see https://example.com for details").kind, .text)
        // A bare word with no dot is not a host.
        XCTAssertNotEqual(Classifier.classify("https://localhost").kind, .url)
    }

    func testFilePaths() {
        XCTAssertEqual(Classifier.classify("/Users/me/Documents/notes.md").kind, .file)
        XCTAssertEqual(Classifier.classify("~/Projects/cp/README.md").kind, .file)
        XCTAssertNotEqual(Classifier.classify("/").kind, .file)
    }

    func testJSON() {
        let object = Classifier.classify("{\"a\": 1, \"b\": 2}")
        XCTAssertEqual(object.kind, .json)
        XCTAssertEqual(object.detail, "2 keys")

        let array = Classifier.classify("[1, 2, 3]")
        XCTAssertEqual(array.kind, .json)
        XCTAssertEqual(array.detail, "3 items")

        // Invalid JSON that merely starts with a brace falls through to code/text.
        XCTAssertNotEqual(Classifier.classify("{not json").kind, .json)
    }

    func testCodeDetection() {
        let swift = """
        struct PullRequestView: View {
            @State private var isExpanded = false
            var body: some View { Text("hi") }
        }
        """
        let result = Classifier.classify(swift)
        XCTAssertEqual(result.kind, .code)
        XCTAssertEqual(result.detail, "swift")

        XCTAssertEqual(Classifier.classify("#!/usr/bin/env bash\necho hello").kind, .code)
    }

    func testProseIsNotCode() {
        let prose = """
        The meeting is at 3pm; please bring the deck. We'll review the numbers \
        and decide whether to ship on Friday or wait for the next cycle.
        """
        XCTAssertEqual(Classifier.classify(prose).kind, .text)
    }

    func testEmptyAndWhitespace() {
        XCTAssertEqual(Classifier.classify("").kind, .text)
        XCTAssertEqual(Classifier.classify("   \n  ").kind, .text)
    }
}
