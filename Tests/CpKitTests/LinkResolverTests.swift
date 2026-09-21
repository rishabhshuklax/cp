import AppKit
import XCTest
@testable import CpKit

/// Answers the resolver's requests from memory, a little slowly, and records
/// them. No request leaves the machine.
final class StubServer: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: [URL] = []
    nonisolated(unsafe) static var delay: TimeInterval = 0.2

    static var requests: [URL] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        seen = []
    }

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        return configuration
    }

    static let favicon: Data = {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.seen.append(url)
        Self.lock.unlock()
        let isIcon = url.path == "/favicon.ico"
        let body = isIcon ? Self.favicon : Data("<html><head><title>Title of \(url.path)</title></head></html>".utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": isIcon ? "image/png" : "text/html"])!
        DispatchQueue.global().asyncAfter(deadline: .now() + (isIcon ? 0 : Self.delay)) { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

final class LinkResolverTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubServer.reset()
    }

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

    /// Fix 16: arrowing onto a link fired the lookup twice; the second call
    /// cancelled the first, the cancelled run was cached as "no title", and the
    /// link never resolved.
    func testACancelledCallerDoesNotSpoilTheLookup() async {
        let resolver = LinkResolver(configuration: StubServer.configuration)
        let url = "https://example.com/pull/1234"

        let first = Task { await resolver.resolve(urlString: url) }
        first.cancel()
        let second = await resolver.resolve(urlString: url)
        _ = await first.value

        XCTAssertEqual(second?.title, "Title of /pull/1234")
        XCTAssertEqual(second?.faviconData, StubServer.favicon)
        let cached = await resolver.cached(for: url)
        XCTAssertEqual(cached?.title, "Title of /pull/1234")
        XCTAssertEqual(StubServer.requests.filter { $0.path == "/pull/1234" }.count, 1, "one request for both callers")
    }

    /// Fix 16: `www.` links had no host, so they could not be looked up at all.
    func testWWWLinksResolve() async {
        let resolver = LinkResolver(configuration: StubServer.configuration)
        let resolved = await resolver.resolve(urlString: "www.apple.com/mac")
        XCTAssertEqual(resolved?.title, "Title of /mac")
        XCTAssertEqual(Set(StubServer.requests.map(\.absoluteString)),
                       ["https://www.apple.com/mac", "https://www.apple.com/favicon.ico"])
        XCTAssertNil(LinkResolver.normalizedURL("not a link at all"))
        XCTAssertNil(LinkResolver.normalizedURL("ftp://example.com/file"))
    }
}

@MainActor
final class LinkPreviewsTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = TestDirectory.make(name)
        StubServer.reset()
    }

    override func tearDown() async throws {
        TestDirectory.remove(directory)
        try await super.tearDown()
    }

    /// Fix 16: titles are persisted, so a link is looked up once, not once a launch.
    func testTitlesPersistAndFaviconsAreKeptByHost() throws {
        let settings = Settings(defaults: MemoryDefaults())
        settings.resolveLinkTitles = true
        let store = ClippingStore(archive: try ClippingArchive(directory: directory), settings: settings, recognizer: nil)
        let previews = LinkPreviews(store: store, settings: settings, resolver: LinkResolver(configuration: StubServer.configuration))
        let link = store.ingest(Clipping(kind: .url, payload: "https://github.com/org/repo/pull/7", detail: "github.com"))

        previews.request(link)
        previews.request(link)   // the selection's double trigger
        XCTAssertTrue(waitUntil(timeout: 5) { store.clipping(withID: link.id)?.linkTitle != nil })
        XCTAssertEqual(store.clipping(withID: link.id)?.displayTitle, "Title of /org/repo/pull/7")
        XCTAssertNotNil(previews.favicon(forHost: "github.com"))
        XCTAssertEqual(StubServer.requests.filter { $0.path != "/favicon.ico" }.count, 1)

        let relaunched = ClippingStore(archive: try ClippingArchive(directory: directory), settings: settings, recognizer: nil)
        XCTAssertEqual(relaunched.clipping(withID: link.id)?.linkTitle, "Title of /org/repo/pull/7")
        let hit = relaunched.search(ClipQuery(text: "pull")).first
        XCTAssertEqual(hit?.clipping.id, link.id)
    }

    func testNothingIsRequestedWhileTheSettingIsOff() {
        let settings = Settings(defaults: MemoryDefaults())
        let store = ClippingStore(archive: nil, settings: settings, recognizer: nil)
        let previews = LinkPreviews(store: store, settings: settings, resolver: LinkResolver(configuration: StubServer.configuration))
        let link = store.ingest(Clipping(kind: .url, payload: "https://example.com/a", detail: "example.com"))
        previews.request(link)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(StubServer.requests.isEmpty)
        XCTAssertNil(store.clipping(withID: link.id)?.linkTitle)
    }
}
