import Foundation

/// The ways a clipping can be pasted.
///
/// Typing is what keeps the list short: a link offers Markdown and "without
/// tracking", JSON offers formatted or one line, a colour offers its other
/// notations. Nobody scrolls past twenty verbs to find the one that applies.
public enum PasteFormat: Hashable, Sendable {
    case original
    case plainText
    case oneLine
    case markdown
    case linkTitle
    case cleanLink
    case codeBlock
    case dedented
    case jsonPretty
    case jsonMinified
    case color(ColorNotation)
    case imageText
    case filePath

    /// For the ⌘K menu, in plain words: "Paste as Markdown link".
    public func menuLabel(for c: Clipping) -> String {
        switch self {
        case .original:
            if c.isConcealed { return "Paste password" }
            switch c.kind {
            case .url: return "Paste link"
            case .richText: return "Paste with formatting"
            case .json, .color: return "Paste as copied"
            case .image: return "Paste image"
            case .file where c.origin == .fileURLs: return PasteFormats.paths(of: c).count > 1 ? "Paste files" : "Paste file"
            default: return "Paste"
            }
        case .plainText: return "Paste as plain text"
        case .oneLine: return "Paste as one line"
        case .markdown: return c.kind == .url ? "Paste as Markdown link" : "Paste as Markdown"
        case .linkTitle: return "Paste page title"
        case .cleanLink: return "Paste without tracking"
        case .codeBlock: return "Paste as code block"
        case .dedented: return "Paste without indentation"
        case .jsonPretty: return "Paste formatted"
        case .jsonMinified: return "Paste on one line"
        case .color(.swiftUI): return "Paste as SwiftUI Color"
        case .color(let notation): return "Paste " + (ColorFormats.strings(for: c.payload)[notation] ?? notation.rawValue)
        case .imageText: return "Paste text from image"
        case .filePath: return PasteFormats.paths(of: c).count > 1 ? "Paste paths" : "Paste path"
        }
    }

    /// For the chip shown after a paste: "Markdown", "Plain", "HEX", "Text".
    public func chipLabel(for c: Clipping) -> String {
        switch self {
        case .original:
            if c.isConcealed { return "Password" }
            switch c.kind {
            case .text, .json, .color: return "As copied"
            case .richText: return "Rich"
            case .url: return "Link"
            case .code: return "Plain"
            case .image: return "Image"
            case .file: return c.origin == .fileURLs ? "File" : "As copied"
            }
        case .plainText: return "Plain"
        case .oneLine, .jsonMinified: return "One line"
        case .markdown: return "Markdown"
        case .linkTitle: return "Title"
        case .cleanLink: return "Clean"
        case .codeBlock: return "Code block"
        case .dedented: return "No indent"
        case .jsonPretty: return "Formatted"
        case .color(.hex): return "HEX"
        case .color(.rgb): return "RGB"
        case .color(.hsl): return "HSL"
        case .color(.swiftUI): return "SwiftUI"
        case .imageText: return "Text"
        case .filePath: return "Path"
        }
    }

    /// An SF Symbol for menus and buttons.
    public var symbolName: String {
        switch self {
        case .original: return "doc.on.clipboard"
        case .plainText: return "textformat"
        case .oneLine: return "arrow.right.to.line"
        case .markdown: return "number"
        case .linkTitle: return "textformat.abc"
        case .cleanLink: return "eye.slash"
        case .codeBlock: return "chevron.left.forwardslash.chevron.right"
        case .dedented: return "decrease.indent"
        case .jsonPretty: return "text.alignleft"
        case .jsonMinified: return "arrow.down.forward.and.arrow.up.backward"
        case .color: return "paintpalette"
        case .imageText: return "text.viewfinder"
        case .filePath: return "folder"
        }
    }
}

public enum PasteFormats {

    /// For ⌘K: the default first, then everything else that applies and would
    /// paste something different.
    public static func menu(for c: Clipping) -> [PasteFormat] {
        ordered(applicable(c), first: naturalDefault(c))
    }

    /// The menu with the settings-aware default first.
    @MainActor
    public static func menu(for c: Clipping, settings: Settings) -> [PasteFormat] {
        ordered(applicable(c), first: defaultFormat(for: c, settings: settings))
    }

    /// The alternatives offered in the chip after a paste, the default among
    /// them. Empty when there is nothing to switch to.
    public static func chip(for c: Clipping) -> [PasteFormat] {
        if c.isConcealed { return [] }
        switch c.kind {
        case .text:
            return c.lineCount > 1 ? [.original, .oneLine] : []
        case .richText:
            return [.original, .plainText, .markdown]
        case .url:
            var formats: [PasteFormat] = [.original]
            if c.linkTitle != nil { formats.append(.linkTitle) }
            formats.append(.markdown)
            if URLTracking.hasTracking(c.payload) { formats.append(.cleanLink) }
            return formats
        case .code:
            return [.original, .codeBlock]
        case .json:
            return [.jsonPretty, .jsonMinified]
        case .color:
            let available = ColorFormats.strings(for: c.payload)
            return ColorNotation.allCases.filter { available[$0] != nil }.map(PasteFormat.color)
        case .image:
            return hasImageText(c) ? [.original, .imageText] : []
        case .file:
            return c.origin == .fileURLs ? [.original, .filePath] : []
        }
    }

    @MainActor
    public static func defaultFormat(for c: Clipping, settings: Settings) -> PasteFormat {
        if c.kind == .richText, !c.isConcealed, settings.pasteRichAsPlain { return .plainText }
        return naturalDefault(c)
    }

    /// The default when settings don't say otherwise: what was copied, except
    /// that JSON pastes formatted and a colour pastes in its own notation.
    static func naturalDefault(_ c: Clipping) -> PasteFormat {
        guard !c.isConcealed else { return .original }
        switch c.kind {
        case .json:
            // Validated when it was classified; the renderer falls back to the
            // original if a legacy clipping turns out not to parse.
            return .jsonPretty
        case .color:
            return ColorFormats.notation(of: c.payload).map(PasteFormat.color) ?? .original
        default:
            return .original
        }
    }

    static func applicable(_ c: Clipping) -> [PasteFormat] {
        if c.isConcealed { return [.original] }
        switch c.kind {
        case .text:
            var formats: [PasteFormat] = [.original]
            if c.lineCount > 1 { formats.append(.oneLine) }
            if TextFormats.dedent(c.payload) != c.payload { formats.append(.dedented) }
            return formats
        case .richText:
            var formats: [PasteFormat] = [.original, .plainText, .markdown]
            if c.lineCount > 1 { formats.append(.oneLine) }
            return formats
        case .url:
            var formats: [PasteFormat] = [.original, .markdown]
            if URLTracking.hasTracking(c.payload) { formats.append(.cleanLink) }
            if c.linkTitle != nil { formats.append(.linkTitle) }
            return formats
        case .code:
            var formats: [PasteFormat] = [.original, .codeBlock]
            if TextFormats.dedent(c.payload) != c.payload { formats.append(.dedented) }
            return formats
        case .json:
            var formats: [PasteFormat] = []
            let pretty = JSONFormatter.pretty(c.payload)
            let minified = JSONFormatter.minified(c.payload)
            if pretty != nil { formats.append(.jsonPretty) }
            if minified != nil { formats.append(.jsonMinified) }
            if c.payload != pretty && c.payload != minified { formats.append(.original) }
            return formats
        case .color:
            let available = ColorFormats.strings(for: c.payload)
            let formats = ColorNotation.allCases.filter { available[$0] != nil }.map(PasteFormat.color)
            return formats.isEmpty ? [.original] : formats
        case .image:
            return hasImageText(c) ? [.original, .imageText] : [.original]
        case .file:
            return c.origin == .fileURLs ? [.original, .filePath] : [.original]
        }
    }

    private static func ordered(_ formats: [PasteFormat], first: PasteFormat) -> [PasteFormat] {
        guard formats.contains(first) else { return formats }
        return [first] + formats.filter { $0 != first }
    }

    private static func hasImageText(_ c: Clipping) -> Bool {
        !(c.ocrText ?? "").isEmpty
    }

    /// The POSIX paths of a `.file` clipping, one per line, `file://` URLs
    /// decoded.
    static func paths(of c: Clipping) -> [String] {
        c.payload.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            if text.hasPrefix("file://"), let url = URL(string: text), url.isFileURL { return url.path }
            return text
        }
    }
}

/// What goes on the pasteboard. Any combination: rich text carries RTF and a
/// plain string, a file carries its URL and its path, an image carries PNG.
public struct PastePayload: Sendable, Equatable {
    public var string: String?
    public var rtf: Data?
    public var png: Data?
    public var fileURLs: [URL]?

    public init(string: String? = nil, rtf: Data? = nil, png: Data? = nil, fileURLs: [URL]? = nil) {
        self.string = string
        self.rtf = rtf
        self.png = png
        self.fileURLs = fileURLs
    }
}

public enum PasteRenderer {

    /// The pasteboard contents for a clipping in a format, or `nil` when the
    /// format has nothing to give (no text in an image, a forgotten password,
    /// an asset gone from disk).
    @MainActor
    public static func payload(for c: Clipping, as format: PasteFormat, store: ClippingStore) -> PastePayload? {
        if c.isConcealed {
            // The text lives only in the store's vault, and only while it lives.
            guard let secret = store.secret(for: c.id), format == .original || format == .plainText else { return nil }
            return PastePayload(string: secret)
        }

        switch format {
        case .original:
            return original(c, store: store)
        case .plainText:
            return c.kind == .image ? nil : PastePayload(string: c.payload)
        case .oneLine:
            return PastePayload(string: TextFormats.oneLine(c.payload))
        case .markdown:
            if c.kind == .url {
                let url = c.payload.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = c.linkTitle ?? c.host ?? url
                return PastePayload(string: TextFormats.markdownLink(label, to: URLTracking.clean(url)))
            }
            if c.kind == .richText, let rtf = rtfData(c, store: store), let markdown = RichText.markdown(fromRTF: rtf) {
                return PastePayload(string: markdown)
            }
            return PastePayload(string: c.payload)
        case .linkTitle:
            return c.linkTitle.map { PastePayload(string: $0) }
        case .cleanLink:
            return PastePayload(string: URLTracking.clean(c.payload))
        case .codeBlock:
            return PastePayload(string: TextFormats.codeBlock(c.payload, language: c.language))
        case .dedented:
            return PastePayload(string: TextFormats.dedent(c.payload))
        case .jsonPretty:
            return PastePayload(string: JSONFormatter.pretty(c.payload) ?? c.payload)
        case .jsonMinified:
            return PastePayload(string: JSONFormatter.minified(c.payload) ?? c.payload)
        case .color(let notation):
            return ColorFormats.strings(for: c.payload)[notation].map { PastePayload(string: $0) }
        case .imageText:
            guard let text = c.ocrText, !text.isEmpty else { return nil }
            return PastePayload(string: text)
        case .filePath:
            let paths = PasteFormats.paths(of: c)
            return paths.isEmpty ? nil : PastePayload(string: paths.joined(separator: "\n"))
        }
    }

    @MainActor
    private static func original(_ c: Clipping, store: ClippingStore) -> PastePayload? {
        switch c.kind {
        case .image:
            guard let file = c.assetFilename, let url = store.assetURL(file),
                  let png = try? Data(contentsOf: url) else { return nil }
            return PastePayload(png: png)
        case .file:
            // File references only for what arrived as files. A path typed into
            // a terminal pastes as the text it was — and a file always brings
            // its path as text, so it pastes into an editor too.
            let paths = PasteFormats.paths(of: c)
            guard c.origin == .fileURLs, !paths.isEmpty else { return PastePayload(string: c.payload) }
            return PastePayload(string: paths.joined(separator: "\n"), fileURLs: paths.map { URL(fileURLWithPath: $0) })
        case .richText:
            return PastePayload(string: c.payload, rtf: rtfData(c, store: store))
        default:
            return PastePayload(string: c.payload)
        }
    }

    @MainActor
    private static func rtfData(_ c: Clipping, store: ClippingStore) -> Data? {
        guard let file = c.richAssetFilename, let url = store.assetURL(file) else { return nil }
        return try? Data(contentsOf: url)
    }
}

/// Plain-text reshaping shared by the formats.
enum TextFormats {

    /// Lines joined with single spaces, blank lines dropped.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Removes the indentation every non-blank line shares, so a snippet lifted
    /// out of a nested function pastes flush instead of drifting right.
    static func dedent(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let indents = lines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }
        guard let common = indents.min(), common > 0 else { return text }
        return lines.map { String($0.dropFirst(min(common, $0.prefix(while: { $0 == " " || $0 == "\t" }).count))) }
            .joined(separator: "\n")
    }

    /// A fenced block, with a fence longer than any run of backticks inside.
    static func codeBlock(_ text: String, language: String?) -> String {
        var longestRun = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longestRun = max(longestRun, run)
        }
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        let hint = language == nil || language == "code" ? "" : language!
        var body = text
        while body.hasSuffix("\n") { body.removeLast() }
        return "\(fence)\(hint)\n\(body)\n\(fence)"
    }

    static func markdownLink(_ label: String, to url: String) -> String {
        let text = label.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        let destination = url.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: " ", with: "%20")
        return "[\(text)](\(destination))"
    }
}
