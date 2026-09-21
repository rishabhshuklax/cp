import AppKit
import Foundation

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
    private var inFlight: Set<String> = []
    private let session: URLSession

    /// Enough to reach `</title>` on any sane page without pulling down a 5 MB
    /// single-page-app bundle.
    private let byteLimit = 64 * 1_024

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        self.session = URLSession(configuration: configuration)
    }

    public func cached(for urlString: String) -> Resolved? {
        cache[urlString]
    }

    public func resolve(urlString: String) async -> Resolved? {
        if let cached = cache[urlString] { return cached }
        guard !inFlight.contains(urlString) else { return nil }
        guard let url = URL(string: urlString), let host = url.host else { return nil }

        inFlight.insert(urlString)
        defer { inFlight.remove(urlString) }

        async let titleTask = fetchTitle(url: url)
        async let faviconTask = fetchFavicon(host: host, scheme: url.scheme ?? "https")

        let resolved = Resolved(title: await titleTask, faviconData: await faviconTask)
        cache[urlString] = resolved
        return resolved
    }

    // MARK: - Fetching

    private func fetchTitle(url: URL) async -> String? {
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

        return Self.parseTitle(from: html)
    }

    private func fetchFavicon(host: String, scheme: String) async -> Data? {
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
