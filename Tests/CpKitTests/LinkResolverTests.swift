import XCTest
@testable import CpKit

final class LinkResolverTests: XCTestCase {

    func testParsesTitle() {
        let html = "<html><head><title>  Hello &amp;\n  World  </title></head><body>x</body></html>"
        XCTAssertEqual(LinkResolver.parseTitle(from: html), "Hello & World")
    }

    func testHandlesTitleWithAttributes() {
        let html = "<title lang=\"en\">Page</title>"
        XCTAssertEqual(LinkResolver.parseTitle(from: html), "Page")
    }

    func testReturnsNilWithoutTitle() {
        XCTAssertNil(LinkResolver.parseTitle(from: "<html><body>no title</body></html>"))
    }
}
