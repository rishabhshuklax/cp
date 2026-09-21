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

extension MarkedText {

    /// Where each word appears in a piece of text, case- and diacritic-blind.
    ///
    /// The search index hands back ranges for a title or a snippet; the hero
    /// shows a preview of the payload, which those ranges do not point into.
    /// This finds them again over the few kilobytes actually on screen.
    public static func ranges(of words: [String], in text: String, limit: Int = 60) -> [NSRange] {
        guard !words.isEmpty, !text.isEmpty else { return [] }
        var spans: [Range<String.Index>] = []
        for word in words where !word.isEmpty {
            var from = text.startIndex
            while from < text.endIndex, spans.count < limit,
                  let found = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive],
                                         range: from..<text.endIndex) {
                spans.append(found)
                from = found.upperBound
            }
        }
        guard !spans.isEmpty else { return [] }
        spans.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = [spans[0]]
        for span in spans.dropFirst() {
            if let last = merged.last, span.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
        return merged.map { NSRange($0, in: text) }
    }
}
