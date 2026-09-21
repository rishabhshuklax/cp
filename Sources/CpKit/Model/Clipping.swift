import Foundation

/// A single captured pasteboard item.
///
/// `payload` always carries a text rendering suitable for search and for pasting
/// back as plain text. Binary content (images) lives beside the archive on disk
/// and is referenced by `assetFilename`, so the index stays small enough to hold
/// entirely in memory and scan without a database.
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
    /// written to the archive.
    public var isConcealed: Bool

    /// Filename (not path) of the binary asset inside the assets directory.
    public var assetFilename: String?
    public var byteCount: Int
    /// Detected language for `.code`, host for `.url`, dimensions for `.image` —
    /// whatever the row's metadata line needs without re-parsing the payload.
    public var detail: String?

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
        byteCount: Int = 0,
        detail: String? = nil
    ) {
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
        self.byteCount = byteCount
        self.detail = detail
    }

    /// Content identity for de-duplication. Two copies of the same string from two
    /// different apps collapse into one clipping with `copyCount == 2`; the source
    /// shown is the most recent one.
    public var dedupeKey: String {
        "\(kind.rawValue)\u{1F}\(payload)"
    }

    /// First non-blank line, collapsed — the row's title when the kind has no
    /// better one to offer.
    public var titleLine: String {
        for line in payload.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return String(trimmed.prefix(200)) }
        }
        return payload.isEmpty ? "(empty)" : "(whitespace)"
    }

    public var lineCount: Int {
        payload.isEmpty ? 0 : payload.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    public var wordCount: Int {
        payload.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }
}
