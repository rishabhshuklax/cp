import SwiftUI

/// Renders a string with the fuzzy-match positions marked, so you can see *why*
/// a row matched. Without this, fuzzy search feels like the list is guessing.
public struct HighlightedText: View {
    private let text: String
    private let highlights: Set<Int>
    private let font: Font

    public init(_ text: String, highlights: [Int], font: Font) {
        self.text = text
        self.highlights = Set(highlights)
        self.font = font
    }

    public var body: some View {
        Text(attributed)
            .font(font)
    }

    private var attributed: AttributedString {
        guard !highlights.isEmpty else { return AttributedString(text) }

        var result = AttributedString()
        for (offset, character) in text.enumerated() {
            var piece = AttributedString(String(character))
            if highlights.contains(offset) {
                piece.backgroundColor = Theme.highlight
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            result.append(piece)
        }
        return result
    }
}
