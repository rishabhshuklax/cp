import Foundation

/// Turns raw pasteboard text into a `ClippingKind` plus the one line of detail the
/// row's metadata needs.
///
/// Deliberately heuristic and deliberately cheap: this runs on every copy, on the
/// main actor's heels, so it must stay well under a millisecond for typical input.
/// Everything expensive (link titles, syntax highlighting) is deferred to selection
/// time. Ordering matters — the checks run most-specific first, because a hex colour
/// is also valid prose and a JSON blob is also valid "code".
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

    public static func classify(_ raw: String) -> Result {
        let text = String(raw.prefix(scanLimit))
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return Result(kind: .text) }

        if let detail = colorDetail(trimmed) {
            return Result(kind: .color, detail: detail)
        }
        if let detail = urlDetail(trimmed) {
            return Result(kind: .url, detail: detail)
        }
        if let detail = filePathDetail(trimmed) {
            return Result(kind: .file, detail: detail)
        }
        if let detail = jsonDetail(trimmed) {
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
              let host = components.host,
              host.contains("."),
              !host.hasPrefix("."),
              !host.hasSuffix(".") else { return nil }
        return host
    }

    // MARK: - File path

    /// Returns the parent directory, abbreviated with `~` where it applies.
    static func filePathDetail(_ text: String) -> String? {
        guard !text.contains("\n") else { return nil }

        var path = text
        if path.hasPrefix("file://") {
            guard let url = URL(string: path) else { return nil }
            path = url.path
        }
        guard path.hasPrefix("/") || path.hasPrefix("~/") else { return nil }
        // A lone "/" or a sentence starting with a slash isn't a path worth typing.
        guard path.count > 2, path.contains("/") else { return nil }

        let expanded = (path as NSString).expandingTildeInPath
        let parent = (expanded as NSString).deletingLastPathComponent
        guard !parent.isEmpty else { return nil }
        return (parent as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - JSON

    /// Returns a `n keys` / `n items` summary. Only objects and arrays count —
    /// a bare `"string"` or `42` is valid JSON but is not what anyone means.
    static func jsonDetail(_ text: String) -> String? {
        let first = text.first
        guard first == "{" || first == "[" else { return nil }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }

        if let dictionary = object as? [String: Any] {
            return "\(dictionary.count) key\(dictionary.count == 1 ? "" : "s")"
        }
        if let array = object as? [Any] {
            return "\(array.count) item\(array.count == 1 ? "" : "s")"
        }
        return nil
    }
}
