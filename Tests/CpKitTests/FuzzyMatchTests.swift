import XCTest
@testable import CpKit

final class FuzzyMatchTests: XCTestCase {

    func testMatchesSubsequence() {
        XCTAssertNotNil(FuzzyMatch.match(needle: "prv", haystack: "PullRequestView"))
        XCTAssertNil(FuzzyMatch.match(needle: "xyz", haystack: "PullRequestView"))
    }

    func testEmptyNeedleMatchesEverything() {
        XCTAssertEqual(FuzzyMatch.match(needle: "", haystack: "anything")?.score, 0)
    }

    func testReturnsMatchedIndices() {
        let hit = FuzzyMatch.match(needle: "abc", haystack: "aXbXc")
        XCTAssertEqual(hit?.indices, [0, 2, 4])
    }

    func testWordBoundariesOutrankInteriorMatches() {
        // "pr" at two word starts should beat "pr" buried mid-word.
        let boundary = FuzzyMatch.match(needle: "pr", haystack: "pull request")
        let interior = FuzzyMatch.match(needle: "pr", haystack: "unprepared")
        XCTAssertNotNil(boundary)
        XCTAssertNotNil(interior)
        XCTAssertGreaterThan(boundary!.score, interior!.score)
    }

    func testConsecutiveRunsScoreHigher() {
        let consecutive = FuzzyMatch.match(needle: "abc", haystack: "abcdef")
        let scattered = FuzzyMatch.match(needle: "abc", haystack: "axbxcx")
        XCTAssertGreaterThan(consecutive!.score, scattered!.score)
    }

    func testIsCaseInsensitive() {
        XCTAssertNotNil(FuzzyMatch.match(needle: "PRV", haystack: "pullrequestview"))
    }
}
