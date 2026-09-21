import Foundation

/// Turns raw pasteboard text into a `ClippingKind` plus the one line of detail the
/// row's metadata needs.
///
/// Deliberately heuristic and deliberately cheap: this runs on every copy, so it
/// must stay well under a millisecond for typical input. Everything expensive
/// (link titles, syntax highlighting) is deferred to selection time. Ordering
/// matters — the checks run most-specific first, because a hex colour is also
/// valid prose and a JSON blob is also valid "code".
public enum Classifier {

    public struct Result: Sendable, Equatable {
        public let kind: ClippingKind
        public let detail: String?
        public init(kind: ClippingKind, detail: String? = nil) {
            self.kind = kind
            self.detail = detail
        }
    }

    // Capped so a 40 MB paste can't turn classification into a linear scan of the
    // whole payload. The head of a document is enough to type it.
    private static let scanLimit = 8_192
    /// JSON is the exception: a response body is routinely bigger than the scan
    /// limit, and only the whole text can prove it parses.
    private static let jsonLimit = 4 * 1_024 * 1_024

    public static func classify(_ raw: String) -> Result {
        let fitsHead = raw.utf8.count <= scanLimit
        let head = fitsHead ? raw : String(raw.prefix(scanLimit))
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return Result(kind: .text) }

        // Colours, links and paths are single tokens; a text too long to scan
        // whole cannot be one.
        if fitsHead {
            if let detail = colorDetail(trimmed) {
                return Result(kind: .color, detail: detail)
            }
            if let detail = urlDetail(trimmed) {
                return Result(kind: .url, detail: detail)
            }
            if let detail = filePathDetail(trimmed) {
                return Result(kind: .file, detail: detail)
            }
        }
        if let first = trimmed.first, first == "{" || first == "[", raw.utf8.count <= jsonLimit,
           let detail = jsonDetail(raw) {
            return Result(kind: .json, detail: detail)
        }
        if let language = CodeHeuristic.detectLanguage(trimmed) {
            return Result(kind: .code, detail: language)
        }
        return Result(kind: .text, detail: nil)
    }

    // MARK: - Colour

    /// `#abc`, `#aabbcc`, `#aabbccdd`, `rgb(…)`, `rgba(…)`, `hsl(…)`, `hsla(…)`.
    /// Returns a normalised label for the metadata line.
    static func colorDetail(_ text: String) -> String? {
        if text.hasPrefix("#") {
            let digits = text.dropFirst()
            let validLengths = [3, 4, 6, 8]
            guard validLengths.contains(digits.count),
                  digits.allSatisfy({ $0.isHexDigit }) else { return nil }
            // `#123` and `#4521` are issue and pull-request numbers far more often
            // than they are colours.
            if digits.count <= 4, digits.allSatisfy({ $0.isASCII && $0.isNumber }) { return nil }
            return "#" + digits.uppercased()
        }

        let lower = text.lowercased()
        for function in ["rgba", "rgb", "hsla", "hsl"] where lower.hasPrefix(function + "(") {
            guard lower.hasSuffix(")") else { return nil }
            let inner = lower.dropFirst(function.count + 1).dropLast()
            // Accept comma- or space-separated components; reject anything with
            // letters left in it so `rgb(var(--x))` doesn't read as a colour.
            let allowed = CharacterSet(charactersIn: "0123456789.,%/ -")
            guard !inner.isEmpty,
                  inner.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
            return text
        }
        return nil
    }

    // MARK: - URL

    /// Returns the host, which is what the row shows next to the favicon.
    static func urlDetail(_ text: String) -> String? {
        // A URL is a single token. Anything with whitespace is prose that happens
        // to contain a link, and belongs to `.text`.
        guard !text.contains(" "), !text.contains("\n") else { return nil }

        let candidate: String
        if text.hasPrefix("http://") || text.hasPrefix("https://") {
            candidate = text
        } else if text.hasPrefix("www.") {
            candidate = "https://" + text
        } else {
            return nil
        }

        guard let components = URLComponents(string: candidate),
              let host = components.host, !host.isEmpty else { return nil }
        // A dotted name, or one of the two hosts a developer copies all day:
        // `localhost:3000` and a bare IPv4 address.
        let isLocal = host == "localhost" || isIPv4(host)
        guard isLocal || (host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")) else { return nil }
        return host
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy { $0.isASCII && $0.isNumber } && (Int(part) ?? 256) < 256
        }
    }

    // MARK: - File path

    /// Absolute paths only count when they start at a real root. `/api/v1/users`,
    /// `// TODO` and `/giphy` all start with a slash and none of them is a file.
    static let pathRoots = [
        "/Users/", "/Volumes/", "/Applications/", "/System/", "/Library/", "/private/",
        "/tmp/", "/opt/", "/usr/", "/etc/", "/var/", "/bin/", "/sbin/", "/dev/", "/nix/",
    ]

    /// Returns the parent directory, abbreviated with `~` where it applies.
    static func filePathDetail(_ text: String) -> String? {
        guard !text.contains("\n"), !text.contains("\r") else { return nil }

        var path = text
        if path.hasPrefix("file://") {
            guard let url = URL(string: path), url.isFileURL else { return nil }
            path = url.path
        }
        // A lone "/" or "~/" isn't a path worth typing.
        guard path.count > 2, !path.hasPrefix("//") else { return nil }

        let isPath: Bool
        if path.hasPrefix("~/") {
            isPath = true
        } else if path.hasPrefix("/") {
            isPath = pathRoots.contains(where: { path.hasPrefix($0) })
                || FileManager.default.fileExists(atPath: path)
        } else {
            isPath = false
        }
        guard isPath else { return nil }

        let expanded = (path as NSString).expandingTildeInPath
        let parent = (expanded as NSString).deletingLastPathComponent
        guard !parent.isEmpty else { return nil }
        return (parent as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - JSON

    /// Returns a `n keys` / `n items` summary. Only objects and arrays count —
    /// a bare `"string"` or `42` is valid JSON but is not what anyone means.
    static func jsonDetail(_ text: String) -> String? {
        guard let summary = JSONFormatter.summary(text) else { return nil }
        if summary.isObject {
            return "\(summary.count) key\(summary.count == 1 ? "" : "s")"
        }
        return "\(summary.count) item\(summary.count == 1 ? "" : "s")"
    }
}
