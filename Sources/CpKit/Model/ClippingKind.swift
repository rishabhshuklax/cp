import Foundation

/// The spine of the whole design: a clipping is a *typed value*, not a string.
///
/// Classification happens once, at capture time, and every downstream decision —
/// how the row renders, which accent colour it gets, what transforms are offered,
/// how it ranks against the frontmost app — reads off this enum. Maccy's central
/// weakness is that it has no equivalent: every clipping is `String` forever, so
/// every row must look the same.
public enum ClippingKind: String, Codable, Sendable, CaseIterable {
    case url
    case color
    case image
    case file
    case code
    case json
    case richText
    case text

    /// Short label for the row's metadata line and the search token `type:`.
    public var token: String { rawValue.lowercased() }

    /// SF Symbol shown when there is no app icon to fall back on.
    public var symbolName: String {
        switch self {
        case .url: return "link"
        case .color: return "paintpalette"
        case .image: return "photo"
        case .file: return "doc"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .json: return "curlybraces"
        case .richText: return "textformat"
        case .text: return "text.alignleft"
        }
    }

    /// How many body lines the row renders before eliding. Code earns more room
    /// than prose because indentation is the only thing distinguishing two
    /// snippets, and one truncated line of leading whitespace distinguishes
    /// nothing at all.
    public var previewLineLimit: Int {
        switch self {
        case .code, .json: return 3
        case .text, .richText: return 2
        case .url, .color, .file, .image: return 1
        }
    }
}
