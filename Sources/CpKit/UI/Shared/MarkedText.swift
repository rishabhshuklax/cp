import SwiftUI

/// Text with the letters you typed marked, and URLs with their tracking marked.
///
/// The ranges come from the search index and are UTF-16 offsets into
/// `displayTitle` or a snippet — never into the payload, which is why a
/// highlight lands on the letters typed instead of drifting sideways on a
/// clipping with an accent in it.
public enum MarkedText {

    /// `string` with `ranges` highlighted.
    public static func highlighted(_ string: String, ranges: [NSRange], font: Font? = nil) -> AttributedString {
        attributed(string, ranges: ranges, font: font) { piece in
            piece.backgroundColor = Theme.mark
        }
    }

    /// A URL with its tracking parameters tinted, so "Paste without tracking"
    /// shows exactly what it would take away.
    public static func url(_ string: String, trackingRanges: [NSRange]) -> AttributedString {
        attributed(string, ranges: trackingRanges, font: nil) { piece in
            piece.foregroundColor = Theme.tracking
        }
    }

    private static func attributed(
        _ string: String,
        ranges: [NSRange],
        font: Font?,
        mark: (inout AttributedString) -> Void
    ) -> AttributedString {
        var result = AttributedString()
        if !ranges.isEmpty {
            var cursor = string.startIndex
            for range in ranges.sorted(by: { $0.location < $1.location }) {
                guard let bounds = Range(range, in: string), bounds.lowerBound >= cursor else { continue }
                result += AttributedString(String(string[cursor..<bounds.lowerBound]))
                var piece = AttributedString(String(string[bounds]))
                mark(&piece)
                result += piece
                cursor = bounds.upperBound
            }
            result += AttributedString(String(string[cursor...]))
        } else {
            result = AttributedString(string)
        }
        if let font { result.font = font }
        return result
    }
}
