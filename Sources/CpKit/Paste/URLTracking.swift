import Foundation

/// The analytics tail that rides along on links copied off the web.
///
/// Parameters are matched by exact name — only `utm_` is a real prefix. The
/// first build matched prefixes, so `si` took `size`, `since` and `sid` with it,
/// and a presigned S3 link lost its `Signature` and stopped working. Everything
/// that is not tracking is kept byte for byte, percent-escapes included.
public enum URLTracking {

    static let trackingNames: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "mc_cid", "mc_eid",
        "igshid", "_hsenc", "_hsmi", "vero_id", "ref_src", "ref_url", "si",
    ]

    static func isTracking(_ name: String) -> Bool {
        let lower = (name.removingPercentEncoding ?? name).lowercased()
        return lower.hasPrefix("utm_") || trackingNames.contains(lower)
    }

    /// The link without its tracking parameters. Drops the `?` when nothing is
    /// left, and keeps the fragment.
    public static func clean(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = split(trimmed) else { return trimmed }
        let kept = parts.parameters.filter { !isTracking(name(of: String(trimmed[$0]))) }
        guard kept.count < parts.parameters.count else { return trimmed }
        var result = String(trimmed[..<parts.questionMark])
        if !kept.isEmpty {
            result += "?" + kept.map { String(trimmed[$0]) }.joined(separator: "&")
        }
        if let fragment = parts.fragment {
            result += String(trimmed[fragment])
        }
        return result
    }

    /// UTF-16 ranges of each tracking parameter (`name=value`, without the
    /// `&`), so a view can dim exactly what "Paste without tracking" removes.
    public static func trackingRanges(in url: String) -> [NSRange] {
        guard let parts = split(url) else { return [] }
        return parts.parameters
            .filter { isTracking(name(of: String(url[$0]))) }
            .map { NSRange($0, in: url) }
    }

    public static func hasTracking(_ url: String) -> Bool {
        !trackingRanges(in: url).isEmpty
    }

    // MARK: - Parsing

    private struct Parts {
        let questionMark: String.Index
        let parameters: [Range<String.Index>]
        /// `#…` to the end, when there is one after the query.
        let fragment: Range<String.Index>?
    }

    /// Splits on the string itself rather than through `URLComponents`, which
    /// re-encodes what it touches.
    private static func split(_ url: String) -> Parts? {
        guard let questionMark = url.firstIndex(of: "?") else { return nil }
        let queryStart = url.index(after: questionMark)
        let hash = url[queryStart...].firstIndex(of: "#")
        let queryEnd = hash ?? url.endIndex

        var parameters: [Range<String.Index>] = []
        var start = queryStart
        while start < queryEnd {
            let end = url[start..<queryEnd].firstIndex(of: "&") ?? queryEnd
            if start < end { parameters.append(start..<end) }
            start = end < queryEnd ? url.index(after: end) : queryEnd
        }
        return Parts(questionMark: questionMark, parameters: parameters, fragment: hash.map { $0..<url.endIndex })
    }

    private static func name(of parameter: String) -> String {
        String(parameter.prefix(while: { $0 != "=" }))
    }
}
