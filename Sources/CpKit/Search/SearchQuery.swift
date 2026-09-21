import Foundation

/// A query language that never looks like one.
///
/// You type `app:xcode auth` and the `app:xcode` half commits to a chip in the
/// search field while `auth` keeps fuzzy-matching content. No syntax to learn:
/// unrecognised text is just search text, so the feature is invisible until you
/// happen to type a prefix that exists.
public struct SearchQuery: Equatable, Sendable {

    public enum Filter: Equatable, Sendable {
        case app(String)
        case kind(ClippingKind)
        case since(Date)
        case pinnedOnly
        case minBytes(Int)

        /// Label for the chip rendered in the search field.
        public var chipLabel: String {
            switch self {
            case .app(let name): return name
            case .kind(let kind): return kind.token
            case .since: return "today"
            case .pinnedOnly: return "pinned"
            case .minBytes(let bytes): return "> \(ByteFormat.short(bytes))"
            }
        }

        public var symbolName: String {
            switch self {
            case .app: return "app.badge"
            case .kind(let kind): return kind.symbolName
            case .since: return "clock"
            case .pinnedOnly: return "pin.fill"
            case .minBytes: return "scalemass"
            }
        }
    }

    public var filters: [Filter]
    public var text: String

    public init(filters: [Filter] = [], text: String = "") {
        self.filters = filters
        self.text = text
    }

    public var isEmpty: Bool { filters.isEmpty && text.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: - Parsing

    public static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> SearchQuery {
        var filters: [Filter] = []
        var freeWords: [String] = []

        for token in input.split(separator: " ", omittingEmptySubsequences: true) {
            if let filter = parseFilter(String(token), now: now, calendar: calendar) {
                filters.append(filter)
            } else {
                freeWords.append(String(token))
            }
        }
        return SearchQuery(filters: filters, text: freeWords.joined(separator: " "))
    }

    private static func parseFilter(_ token: String, now: Date, calendar: Calendar) -> Filter? {
        let lower = token.lowercased()

        switch lower {
        case "today":
            return .since(calendar.startOfDay(for: now))
        case "yesterday":
            let startOfToday = calendar.startOfDay(for: now)
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else { return nil }
            return .since(yesterday)
        case "week":
            guard let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) else { return nil }
            return .since(weekAgo)
        case "pinned":
            return .pinnedOnly
        default:
            break
        }

        if lower.hasPrefix(">"), let bytes = ByteFormat.parse(String(lower.dropFirst())) {
            return .minBytes(bytes)
        }

        guard let colon = lower.firstIndex(of: ":") else { return nil }
        let key = String(lower[lower.startIndex..<colon])
        let value = String(lower[lower.index(after: colon)...])
        guard !value.isEmpty else { return nil }

        switch key {
        case "app", "from":
            return .app(value)
        case "type", "kind", "is":
            // `link` and `img` read better than the raw case names.
            let aliases: [String: ClippingKind] = [
                "link": .url, "links": .url, "img": .image, "images": .image,
                "photo": .image, "snippet": .code, "rich": .richText,
            ]
            if let aliased = aliases[value] { return .kind(aliased) }
            return ClippingKind(rawValue: value).map(Filter.kind)
        default:
            return nil
        }
    }

    // MARK: - Matching

    /// Hard filters. A clipping either survives these or it is not in the list.
    public func passesFilters(_ clipping: Clipping) -> Bool {
        for filter in filters {
            switch filter {
            case .app(let needle):
                let name = (clipping.sourceAppName ?? "").lowercased()
                let bundle = (clipping.sourceBundleID ?? "").lowercased()
                guard name.contains(needle) || bundle.contains(needle) else { return false }
            case .kind(let kind):
                guard clipping.kind == kind else { return false }
            case .since(let date):
                guard clipping.lastCopiedAt >= date else { return false }
            case .pinnedOnly:
                guard clipping.isPinned else { return false }
            case .minBytes(let bytes):
                guard clipping.byteCount >= bytes else { return false }
            }
        }
        return true
    }
}

public enum ByteFormat {
    public static func short(_ bytes: Int) -> String {
        if bytes < 1_024 { return "\(bytes) B" }
        if bytes < 1_024 * 1_024 { return String(format: "%.1f KB", Double(bytes) / 1_024) }
        return String(format: "%.1f MB", Double(bytes) / (1_024 * 1_024))
    }

    /// Parses `1kb`, `20k`, `2mb`, `512` into a byte count.
    public static func parse(_ input: String) -> Int? {
        let trimmed = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let multipliers: [(suffix: String, factor: Int)] = [
            ("mb", 1_024 * 1_024), ("m", 1_024 * 1_024),
            ("kb", 1_024), ("k", 1_024),
            ("b", 1),
        ]
        for (suffix, factor) in multipliers where trimmed.hasSuffix(suffix) {
            let number = trimmed.dropLast(suffix.count)
            guard let value = Double(number) else { return nil }
            return Int(value * Double(factor))
        }
        return Int(trimmed)
    }
}
