import CoreGraphics
import Foundation

/// How the content reached the pasteboard, which is not always what it turned
/// out to be. A path typed into a terminal and a file copied in Finder are both
/// `.file` clippings, but only the second should paste back as a file.
public enum ClipOrigin: String, Codable, Sendable {
    case text
    case fileURLs
    case image
    case richText
}

/// One line of text found in an image. `box` is normalized to 0…1 with a
/// top-left origin, so a view can scale it straight onto the drawn image.
public struct OCRLine: Codable, Sendable, Equatable {
    public var text: String
    public var box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }
}

/// A single captured pasteboard item.
///
/// `payload` always carries a text rendering suitable for search and for pasting
/// back as plain text. Binary content (images, the RTF behind rich text) lives
/// beside the archive on disk and is referenced by filename, so the index stays
/// small enough to hold entirely in memory and scan without a database.
///
/// Everything a row needs to draw — title, line and word counts — is computed
/// once at capture and stored, because recomputing them from a 1 MB payload on
/// every render is what froze the first build.
public struct Clipping: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var kind: ClippingKind
    public var payload: String

    /// Bundle identifier of whatever was frontmost when this was copied. The single
    /// highest-signal retrieval cue there is, which is why it earns a slot in the
    /// row rather than a tooltip.
    public var sourceBundleID: String?
    public var sourceAppName: String?

    public var createdAt: Date
    /// Bumped instead of inserting a duplicate when the same content is re-copied.
    public var lastCopiedAt: Date
    public var copyCount: Int

    public var isPinned: Bool
    /// True when the source marked the pasteboard concealed, or the content matched
    /// a secret pattern. Concealed clippings are held in memory only and never
    /// written to the archive; their text lives in the store's vault, not here.
    public var isConcealed: Bool

    /// Filename (not path) of the binary asset inside the assets directory.
    public var assetFilename: String?
    public var byteCount: Int
    /// Detected language for `.code`, host for `.url`, parent folder for `.file` —
    /// whatever the row's metadata line needs without re-parsing the payload.
    public var detail: String?

    /// The row's headline, computed at capture: the first non-blank line for text,
    /// the URL for a link, the file name for a path, "Image", the normalized
    /// notation for a colour, "Password" for a concealed item.
    public var title: String
    public var lineCount: Int
    public var wordCount: Int
    /// SHA-256 of the image bytes (hex, first 32 characters). The dedupe key for
    /// images: two different screenshots can share a size, never a hash.
    public var contentHash: String?
    public var origin: ClipOrigin
    /// The RTF behind a `.richText` clipping, so pasting it keeps its formatting.
    public var richAssetFilename: String?
    /// Text recognized in an image. `""` means recognition ran and found nothing;
    /// `nil` means it has not run.
    public var ocrText: String?
    public var ocrLines: [OCRLine]?
    /// The page title of a link, once resolved. Persisted, so a link is only ever
    /// looked up once.
    public var linkTitle: String?
    /// Pixels, not points: a Retina screenshot is 2880×1800, not 1440×900.
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// The page a copy came from, when the browser says (`org.chromium.source-url`).
    public var sourceURL: String?
    /// When a concealed clipping, and its text, will be forgotten. Session-only,
    /// like everything else about a concealed clipping.
    public var expiresAt: Date?

    public init(
        id: UUID = UUID(),
        kind: ClippingKind,
        payload: String,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        createdAt: Date = Date(),
        lastCopiedAt: Date? = nil,
        copyCount: Int = 1,
        isPinned: Bool = false,
        isConcealed: Bool = false,
        assetFilename: String? = nil,
        byteCount: Int? = nil,
        detail: String? = nil,
        title: String? = nil,
        contentHash: String? = nil,
        origin: ClipOrigin? = nil,
        richAssetFilename: String? = nil,
        ocrText: String? = nil,
        ocrLines: [OCRLine]? = nil,
        linkTitle: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        sourceURL: String? = nil,
        expiresAt: Date? = nil
    ) {
        // Pasteboard strings arrive bridged from NSString. Making them native UTF-8
        // once here keeps every later byte-level scan (counts, search) linear.
        var payload = payload
        payload.makeContiguousUTF8()

        self.id = id
        self.kind = kind
        self.payload = payload
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.createdAt = createdAt
        self.lastCopiedAt = lastCopiedAt ?? createdAt
        self.copyCount = copyCount
        self.isPinned = isPinned
        self.isConcealed = isConcealed
        self.assetFilename = assetFilename
        self.byteCount = byteCount ?? payload.utf8.count
        self.detail = detail
        self.title = title ?? Self.makeTitle(kind: kind, payload: payload, detail: detail, isConcealed: isConcealed)
        self.lineCount = Self.countLines(payload)
        self.wordCount = Self.countWords(payload)
        self.contentHash = contentHash
        self.origin = origin ?? Self.defaultOrigin(kind: kind, detail: detail)
        self.richAssetFilename = richAssetFilename
        self.ocrText = ocrText
        self.ocrLines = ocrLines
        self.linkTitle = linkTitle
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sourceURL = sourceURL
        self.expiresAt = expiresAt
    }

    // MARK: - Derived

    /// What a row shows as its headline: the page title once a link resolves.
    public var displayTitle: String { linkTitle ?? title }

    /// Host of a `.url` clipping, `www.` links included.
    public var host: String? {
        guard kind == .url else { return nil }
        if let detail, !detail.isEmpty { return detail }
        return Classifier.urlDetail(payload.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Detected language of a `.code` clipping.
    public var language: String? {
        kind == .code ? detail : nil
    }

    /// Kept for the old UI, which is replaced in the next phase. Use `title`.
    public var titleLine: String { title }

    /// The head of the payload, for previews. A text view laid out over a 1 MB
    /// string takes over a minute; nothing needs to show more than a screenful.
    /// Cut at a line boundary when one falls in the second half of the limit, so
    /// the preview does not end mid-line.
    public func previewText(limit: Int = 16_384) -> String {
        guard limit > 0 else { return "" }
        guard payload.utf8.count > limit else { return payload }
        let head = payload.prefix(limit)
        guard head.endIndex < payload.endIndex else { return payload }
        if let newline = head.lastIndex(where: { $0.isNewline }),
           head.distance(from: head.startIndex, to: newline) >= limit / 2 {
            return String(payload[..<newline])
        }
        return String(head)
    }

    /// Content identity for de-duplication. Two copies of the same string from two
    /// different apps collapse into one clipping with `copyCount == 2`; the source
    /// shown is the most recent one. Images collapse only on identical bytes, and
    /// concealed clippings never collapse: each keeps its own secret and reason.
    public var dedupeKey: String {
        if isConcealed { return "concealed\u{1F}\(id.uuidString)" }
        if kind == .image { return "image\u{1F}\(contentHash ?? id.uuidString)" }
        return "\(kind.rawValue)\u{1F}\(payload)"
    }

    // MARK: - Capture-time computation

    static func makeTitle(kind: ClippingKind, payload: String, detail: String?, isConcealed: Bool) -> String {
        if isConcealed { return "Password" }
        switch kind {
        case .url:
            return String(payload.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
        case .file:
            let first = firstNonBlankLine(payload)
            var path = first
            if first.hasPrefix("file://"), let url = URL(string: first), url.isFileURL { path = url.path }
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? first : name
        case .image:
            return "Image"
        case .color:
            return detail ?? payload.trimmingCharacters(in: .whitespacesAndNewlines)
        case .text, .code, .json, .richText:
            return firstNonBlankLine(payload)
        }
    }

    /// First non-blank line, trimmed, at most 200 characters. Finds line breaks
    /// on UTF-8 bytes so a megabyte with no newline costs one byte scan, not a
    /// grapheme walk.
    static func firstNonBlankLine(_ text: String) -> String {
        let utf8 = text.utf8
        var start = utf8.startIndex
        while start < utf8.endIndex {
            var end = start
            while end < utf8.endIndex, utf8[end] != 0x0A, utf8[end] != 0x0D {
                utf8.formIndex(after: &end)
            }
            let trimmed = text[start..<end].drop(while: { $0.isWhitespace })
            if !trimmed.isEmpty {
                return String(trimmed.prefix(200)).trimmingCharacters(in: .whitespaces)
            }
            start = end < utf8.endIndex ? utf8.index(after: end) : end
        }
        return text.isEmpty ? "(empty)" : "(whitespace)"
    }

    static func countLines(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var newlines = 0
        let counted: Void? = text.utf8.withContiguousStorageIfAvailable { bytes in
            for byte in bytes where byte == 0x0A { newlines += 1 }
        }
        if counted == nil {
            for byte in text.utf8 where byte == 0x0A { newlines += 1 }
        }
        return newlines + 1
    }

    static func countWords(_ text: String) -> Int {
        var words = 0
        var inWord = false
        func step(_ byte: UInt8) {
            let isSeparator = byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D
            if isSeparator {
                inWord = false
            } else if !inWord {
                inWord = true
                words += 1
            }
        }
        let counted: Void? = text.utf8.withContiguousStorageIfAvailable { bytes in
            for byte in bytes { step(byte) }
        }
        if counted == nil {
            for byte in text.utf8 { step(byte) }
        }
        return words
    }

    /// For clippings that predate `origin`. Only file URLs can arrive as several
    /// files at once, so "3 files" is the one detail that proves the flavour.
    static func defaultOrigin(kind: ClippingKind, detail: String?) -> ClipOrigin {
        switch kind {
        case .image: return .image
        case .richText: return .richText
        case .file:
            if let detail, detail.hasSuffix(" files"), detail.first?.isNumber == true { return .fileURLs }
            return .text
        default: return .text
        }
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, kind, payload, sourceBundleID, sourceAppName, createdAt, lastCopiedAt, copyCount
        case isPinned, isConcealed, assetFilename, byteCount, detail
        case title, lineCount, wordCount, contentHash, origin, richAssetFilename
        case ocrText, ocrLines, linkTitle, pixelWidth, pixelHeight, sourceURL
        // `expiresAt` is deliberately absent: it only exists for concealed
        // clippings, which never reach the archive.
    }

    /// Lines written before the redesign carry none of the new fields. Everything
    /// that can be derived from the payload is derived here, so old history loads
    /// looking exactly like new captures.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(ClippingKind.self, forKey: .kind)
        var payload = try container.decode(String.self, forKey: .payload)
        payload.makeContiguousUTF8()
        self.payload = payload
        sourceBundleID = try container.decodeIfPresent(String.self, forKey: .sourceBundleID)
        sourceAppName = try container.decodeIfPresent(String.self, forKey: .sourceAppName)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastCopiedAt = try container.decodeIfPresent(Date.self, forKey: .lastCopiedAt) ?? createdAt
        copyCount = try container.decodeIfPresent(Int.self, forKey: .copyCount) ?? 1
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isConcealed = try container.decodeIfPresent(Bool.self, forKey: .isConcealed) ?? false
        assetFilename = try container.decodeIfPresent(String.self, forKey: .assetFilename)
        byteCount = try container.decodeIfPresent(Int.self, forKey: .byteCount) ?? payload.utf8.count
        detail = try container.decodeIfPresent(String.self, forKey: .detail)

        title = try container.decodeIfPresent(String.self, forKey: .title)
            ?? Self.makeTitle(kind: kind, payload: payload, detail: detail, isConcealed: isConcealed)
        lineCount = try container.decodeIfPresent(Int.self, forKey: .lineCount) ?? Self.countLines(payload)
        wordCount = try container.decodeIfPresent(Int.self, forKey: .wordCount) ?? Self.countWords(payload)
        contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
        origin = try container.decodeIfPresent(ClipOrigin.self, forKey: .origin)
            ?? Self.defaultOrigin(kind: kind, detail: detail)
        richAssetFilename = try container.decodeIfPresent(String.self, forKey: .richAssetFilename)
        ocrText = try container.decodeIfPresent(String.self, forKey: .ocrText)
        ocrLines = try container.decodeIfPresent([OCRLine].self, forKey: .ocrLines)
        linkTitle = try container.decodeIfPresent(String.self, forKey: .linkTitle)
        pixelWidth = try container.decodeIfPresent(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decodeIfPresent(Int.self, forKey: .pixelHeight)
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL)
        expiresAt = nil
    }
}
