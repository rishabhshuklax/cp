import AppKit
import Foundation

/// What rich text on the pasteboard actually carries.
///
/// Every RTF names a font, so "has a font attribute" was true of every RTF and
/// every copy from a text view became `.richText`. Formatting counts as real
/// only when it would survive being noticed: bold or italic, underline or
/// strikethrough, a link, a colour that is not black, white or the label
/// colour, or more than one font or size.
enum RichText {

    static func hasRealFormatting(_ text: NSAttributedString) -> Bool {
        var fonts: Set<String> = []
        var isReal = false
        let string = text.string as NSString
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, stop in
            // A trailing newline in another size is not formatting anyone sees.
            let visible = string.substring(with: range).contains { !$0.isWhitespace }
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if visible, traits.contains(.bold) || traits.contains(.italic) { isReal = true }
                if visible { fonts.insert("\(font.familyName ?? font.fontName)|\(font.pointSize)") }
            }
            if let underline = attributes[.underlineStyle] as? Int, underline != 0, visible { isReal = true }
            if let strike = attributes[.strikethroughStyle] as? Int, strike != 0, visible { isReal = true }
            if attributes[.link] != nil { isReal = true }
            if let color = attributes[.foregroundColor] as? NSColor, visible, !isPlainInk(color) { isReal = true }
            if isReal { stop.pointee = true }
        }
        return isReal || fonts.count > 1
    }

    /// Black, white, or a grey close enough to either: what `labelColor`
    /// becomes in light and dark mode.
    static func isPlainInk(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return true }
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        guard let high = channels.max(), let low = channels.min() else { return true }
        let isGrey = high - low < 0.05
        return isGrey && (high < 0.3 || low > 0.75)
    }

    // MARK: - Markdown

    static func markdown(fromRTF data: Data) -> String? {
        guard let text = NSAttributedString(rtf: data, documentAttributes: nil) else { return nil }
        return markdown(from: text)
    }

    /// Bold as `**`, italic as `*`, links as `[text](url)`. Emphasis never spans
    /// a line break and never starts or ends on a space, which Markdown would
    /// not read as emphasis.
    static func markdown(from text: NSAttributedString) -> String {
        struct Run {
            var text: String
            var bold: Bool
            var italic: Bool
            var link: String?
        }
        var runs: [Run] = []
        let string = text.string as NSString
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var bold = false
            var italic = false
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                bold = traits.contains(.bold)
                italic = traits.contains(.italic)
            }
            let link = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String
            let piece = string.substring(with: range)
            // Runs differing only in colour or size merge, so they don't leave
            // `****` seams behind.
            if var last = runs.last, last.bold == bold, last.italic == italic, last.link == link {
                last.text += piece
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(text: piece, bold: bold, italic: italic, link: link))
            }
        }

        var output = ""
        for run in runs {
            let marker = run.bold && run.italic ? "***" : run.bold ? "**" : run.italic ? "*" : ""
            let lines = run.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                if index > 0 { output += "\n" }
                let leading = line.prefix(while: { $0.isWhitespace })
                let trailing = String(line.dropFirst(leading.count).reversed().prefix(while: { $0.isWhitespace }).reversed())
                let core = line.dropFirst(leading.count).dropLast(trailing.count)
                guard !core.isEmpty else {
                    output += line
                    continue
                }
                var piece = marker + core + marker
                if let link = run.link {
                    let destination = link.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
                    piece = "[\(piece)](\(destination))"
                }
                output += leading + piece + trailing
            }
        }
        return output
    }
}
