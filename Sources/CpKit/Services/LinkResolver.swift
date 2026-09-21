import AppKit
import Foundation
import Observation

/// Turns a URL clipping into a readable row: the page's own title and favicon,
/// so `github.com/org/repo/pull/1234` reads as the pull request's name.
///
/// Three deliberate constraints, because this is the one feature in the app that
/// touches the network on your behalf:
///
/// 1. **Opt-in.** Off until `Settings.resolveLinkTitles` is turned on.
/// 2. **Lazy.** Resolution runs when a link is *selected*, never at capture, so
///    copying fifty links costs zero requests until you go hunting for one.
/// 3. **First-party only.** The favicon comes from the site itself, not from a
///    third-party favicon proxy, which would hand your browsing history to a
///    service you never chose.
public actor LinkResolver {

    public struct Resolved: Sendable, Equatable {
        public let title: String?
        public let faviconData: Data?
    }

    private var cache: [String: Resolved] = [:]
    /// Failures are retried, but not on every arrow key: a dead link waits a
    /// few minutes.
    private var failures: [String: Date] = [:]
    private var inFlight: [String: Task<Resolved?, Never>] = [:]
    private let session: URLSession

    /// Enough to reach `</title>` on any sane page without pulling down a 5 MB
    /// single-page-app bundle.
    private let byteLimit = 64 * 1_024
    private let retryAfter: TimeInterval = 300

    public init() {
        self.init(configuration: .ephemeral)
    }

    /// For tests, which answer requests themselves.
    init(configuration: URLSessionConfiguration) {
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        self.session = URLSession(configuration: configuration)
    }

    public func cached(for urlString: String) -> Resolved? {
        Self.normalizedURL(urlString).flatMap { cache[$0.absoluteString] }
    }

    /// The page's title and favicon. Callers asking for the same link at once
    /// share one request, and the request runs in its own task: arrowing past a
    /// link cancels the caller, and the old code then cached that cancelled run
    /// as "no title", so the link never resolved.
    public func resolve(urlString: String) async -> Resolved? {
        guard let url = Self.normalizedURL(urlString), let host = url.host else { return nil }
        let key = url.absoluteString
        if let cached = cache[key] { return cached }
        if let failed = failures[key], Date().timeIntervalSince(failed) < retryAfter { return nil }
        if let running = inFlight[key] { return await running.value }

        let task = Task { await Self.fetch(url, host: host, session: session, byteLimit: byteLimit) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result, result.title != nil || result.faviconData != nil {
            cache[key] = result
            failures[key] = nil
        } else {
            failures[key] = Date()
        }
        return result
    }

    /// `www.apple.com/mac` has no scheme, so `URL` sees no host in it.
    static func normalizedURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    // MARK: - Fetching

    private static func fetch(_ url: URL, host: String, session: URLSession, byteLimit: Int) async -> Resolved? {
        async let title = fetchTitle(url: url, session: session, byteLimit: byteLimit)
        async let favicon = fetchFavicon(host: host, scheme: url.scheme ?? "https", session: session)
        return Resolved(title: await title, faviconData: await favicon)
    }

    private static func fetchTitle(url: URL, session: URLSession, byteLimit: Int) async -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Ask for the head of the document only. Servers that ignore Range just
        // send the whole body, which the byte limit below still truncates.
        request.setValue("bytes=0-\(byteLimit)", forHTTPHeaderField: "Range")
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request) else { return nil }
        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { return nil }

        let head = data.prefix(byteLimit)
        guard let html = String(data: head, encoding: .utf8)
            ?? String(data: head, encoding: .isoLatin1) else { return nil }

        return parseTitle(from: html)
    }

    private static func fetchFavicon(host: String, scheme: String, session: URLSession) async -> Data? {
        guard let url = URL(string: "\(scheme)://\(host)/favicon.ico") else { return nil }
        guard let (data, response) = try? await session.data(from: url) else { return nil }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        // Reject anything implausibly large for an icon, and anything AppKit can't
        // decode — a 404 page served as 200 is common and is not a favicon.
        guard data.count < 256 * 1_024, NSImage(data: data) != nil else { return nil }
        return data
    }

    // MARK: - Parsing

    /// Extracts and unescapes the contents of the first `<title>` element.
    static func parseTitle(from html: String) -> String? {
        let lower = html.lowercased()
        guard let openRange = lower.range(of: "<title") else { return nil }
        guard let contentStart = lower.range(of: ">", range: openRange.upperBound..<lower.endIndex) else { return nil }
        guard let closeRange = lower.range(of: "</title>", range: contentStart.upperBound..<lower.endIndex) else { return nil }

        let raw = String(html[contentStart.upperBound..<closeRange.lowerBound])
        let collapsed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let unescaped = collapsed
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")

        // Collapse runs of spaces left behind by the newline replacement.
        let squeezed = unescaped.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return squeezed.isEmpty ? nil : String(squeezed.prefix(300))
    }
}

/// Link titles and favicons for the UI: ask for a link as it is shown or
/// selected, read the favicon back by host, and the title arrives on the
/// clipping itself — persisted, so each link is looked up once, ever.
@MainActor
@Observable
public final class LinkPreviews {

    /// Favicons by host, for this session.
    public private(set) var favicons: [String: NSImage] = [:]

    @ObservationIgnored private let store: ClippingStore
    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let resolver: LinkResolver
    @ObservationIgnored private var requested: Set<UUID> = []

    public init(store: ClippingStore, settings: Settings, resolver: LinkResolver = LinkResolver()) {
        self.store = store
        self.settings = settings
        self.resolver = resolver
    }

    /// Looks up a link's title and favicon, unless link titles are off or there
    /// is nothing left to learn. Safe to call on every selection change: a link
    /// already asked for is not asked for again.
    public func request(_ c: Clipping) {
        guard settings.resolveLinkTitles, c.kind == .url, !c.isConcealed else { return }
        let host = c.host?.lowercased()
        let needsTitle = c.linkTitle == nil
        let needsIcon = host.map { favicons[$0] == nil } ?? false
        guard needsTitle || needsIcon, !requested.contains(c.id) else { return }

        requested.insert(c.id)
        let id = c.id
        let url = c.payload
        let resolver = self.resolver
        Task { [weak self] in
            let resolved = await resolver.resolve(urlString: url)
            guard let self else { return }
            guard let resolved else {
                // Let a later selection try again; the resolver spaces retries.
                self.requested.remove(id)
                return
            }
            self.apply(resolved, to: id, host: host)
        }
    }

    public func favicon(forHost host: String) -> NSImage? {
        favicons[host.lowercased()]
    }

    private func apply(_ resolved: LinkResolver.Resolved, to id: UUID, host: String?) {
        if let data = resolved.faviconData, let host, favicons[host] == nil, let image = NSImage(data: data) {
            image.size = NSSize(width: 16, height: 16)
            favicons[host] = image
        }
        if let title = resolved.title, var current = store.clipping(withID: id), current.linkTitle != title {
            current.linkTitle = title
            store.update(current)
        }
    }
}
