import AppKit
import SwiftUI

/// Rich text, shown as itself.
///
/// The RTF is the clipping's, but its sizes and colours are the source app's —
/// a 9pt grey run from an email would be unreadable in the hero. What survives
/// is the formatting that carries meaning: bold, italic, underline, strike and
/// links, redrawn at the hero's size in the hero's ink.
public enum RichPreview {

    public static func attributed(rtf: Data, size: CGFloat, limit: Int = 4_000) -> AttributedString? {
        guard let text = NSAttributedString(rtf: rtf, documentAttributes: nil) else { return nil }
        return attributed(text, size: size, limit: limit)
    }

    public static func attributed(_ text: NSAttributedString, size: CGFloat, limit: Int = 4_000) -> AttributedString {
        let string = text.string as NSString
        let length = min(text.length, limit)
        var result = AttributedString()

        text.enumerateAttributes(in: NSRange(location: 0, length: length)) { attributes, range, _ in
            var piece = AttributedString(string.substring(with: range))
            var font = Font.system(size: size)
            if let source = attributes[.font] as? NSFont {
                let traits = source.fontDescriptor.symbolicTraits
                if traits.contains(.bold) { font = font.bold() }
                if traits.contains(.italic) { font = font.italic() }
                if traits.contains(.monoSpace) { font = .system(size: size - 1.5, design: .monospaced) }
            }
            piece.font = font
            if let underline = attributes[.underlineStyle] as? Int, underline != 0 { piece.underlineStyle = .single }
            if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { piece.strikethroughStyle = .single }
            if attributes[.link] != nil {
                piece.foregroundColor = Theme.link
                piece.underlineStyle = .single
            }
            result += piece
        }
        return result
    }
}
