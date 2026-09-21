import Foundation

/// Which part of history a query looks at.
public enum ClipScope: Sendable {
    case recent
    case pinned
}

public enum DayRange: Hashable, Sendable {
    case today
    case yesterday
    /// The last seven days, not the calendar week: "last week" on a Monday
    /// should still find Friday.
    case thisWeek
}

/// A hard filter: a clipping either passes or is not in the results. Filters of
/// the same sort widen each other (Links or Images); different sorts narrow
/// (Links from Safari).
public enum ClipFilter: Hashable, Sendable {
    case kind(ClippingKind)
    case app(bundleID: String, name: String)
    case day(DayRange)
    case pinned

    public var label: String {
        switch self {
        case .kind(let kind):
            switch kind {
            case .url: return "Links"
            case .image: return "Images"
            case .code: return "Code"
            case .color: return "Colours"
            case .file: return "Files"
            case .json: return "JSON"
            case .richText: return "Rich text"
            case .text: return "Text"
            }
        case .app(_, let name): return "From \(name)"
        case .day(.today): return "Today"
        case .day(.yesterday): return "Yesterday"
        case .day(.thisWeek): return "This week"
        case .pinned: return "Pinned"
        }
    }

    public var symbolName: String {
        switch self {
        case .kind(let kind): return kind.symbolName
        case .app: return "app.badge"
        case .day: return "calendar"
        case .pinned: return "pin.fill"
        }
    }
}

public struct ClipQuery: Sendable {
    public var text: String
    public var filters: [ClipFilter]
    public var scope: ClipScope

    public init(text: String = "", filters: [ClipFilter] = [], scope: ClipScope = .recent) {
        self.text = text
        self.filters = filters
        self.scope = scope
    }
}

/// Where a hit's strongest non-title evidence was found.
public enum MatchField: Sendable {
    case title
    case body
    case imageText
    case link
    case app
    case path
}

public struct ClipHit: Identifiable, Sendable, Equatable {
    public let clipping: Clipping
    public let score: Int
    public let field: MatchField?
    /// UTF-16 ranges in `clipping.displayTitle`, one per run of typed letters.
    public let titleRanges: [NSRange]
    /// One line, at most 120 characters, around the first match outside the title.
    public let snippet: String?
    /// UTF-16 ranges in `snippet`.
    public let snippetRanges: [NSRange]

    public var id: UUID { clipping.id }

    public init(
        clipping: Clipping,
        score: Int = 0,
        field: MatchField? = nil,
        titleRanges: [NSRange] = [],
        snippet: String? = nil,
        snippetRanges: [NSRange] = []
    ) {
        self.clipping = clipping
        self.score = score
        self.field = field
        self.titleRanges = titleRanges
        self.snippet = snippet
        self.snippetRanges = snippetRanges
    }
}

// MARK: - Words and suggestions

/// Words the search field offers to turn into filters. Offered, never applied
/// silently: someone searching for "json" may mean the word.
enum ClipSearch {

    static let kindWords: [String: ClippingKind] = [
        "links": .url, "link": .url,
        "images": .image, "image": .image, "screenshots": .image, "screenshot": .image,
        "code": .code,
        "colours": .color, "colors": .color, "colour": .color, "color": .color,
        "files": .file, "file": .file,
        "json": .json,
        "text": .text,
    ]

    static let dayWords: [String: DayRange] = [
        "today": .today, "yesterday": .yesterday, "week": .thisWeek,
    ]

    /// Folded query words, without repeats. Every one must match.
    static func words(in text: String) -> [[UInt8]] {
        var seen = Set<[UInt8]>()
        var result: [[UInt8]] = []
        for piece in text.split(whereSeparator: { $0.isWhitespace }) {
            let folded = FoldedText(piece).bytes
            guard !folded.isEmpty, seen.insert(folded).inserted else { continue }
            result.append(folded)
        }
        return result
    }

    static func suggestion(
        for text: String,
        apps: [(bundleID: String, name: String, count: Int)]
    ) -> ClipFilter? {
        // Only while a word is being typed: a trailing space means it is finished.
        guard let last = text.last, !last.isWhitespace,
              let word = text.split(whereSeparator: { $0.isWhitespace }).last else { return nil }
        let folded = FoldedText(word).bytes
        guard folded.count >= 3 else { return nil }
        let key = String(decoding: folded, as: UTF8.self)
        if let kind = kindWords[key] { return .kind(kind) }
        if let day = dayWords[key] { return .day(day) }
        // Apps present in history, most used first; any word of the name counts,
        // so "chr" finds Google Chrome.
        for app in apps {
            let words = app.name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." })
            if words.contains(where: { FoldedText($0).bytes.starts(with: folded) }) {
                return .app(bundleID: app.bundleID, name: app.name)
            }
        }
        return nil
    }
}

// MARK: - The engine

/// Folded text per clipping, built on first use and dropped when the store
/// changes that clipping. A keystroke then costs a byte search per field, not
/// a re-fold of two megabytes of history.
final class SearchIndex {

    struct Field {
        let text: String
        let folded: FoldedText

        init(_ text: String) {
            self.text = text
            self.folded = FoldedText(text)
        }
    }

    struct Entry {
        /// `displayTitle`, which is what the row shows and the ranges point into.
        let title: Field
        /// Body, image text, link, path — whichever this kind has, best first.
        let others: [(field: MatchField, text: Field)]
        let app: Field?
    }

    /// Only the head of a big payload is searched; nobody finds a 1 MB log by a
    /// word on its last line, and scanning it would cost every keystroke.
    static let bodyLimit = 64 * 1_024

    private var entries: [UUID: Entry] = [:]

    func invalidate(_ id: UUID) {
        entries[id] = nil
    }

    func removeAll() {
        entries.removeAll()
    }

    func entry(for clipping: Clipping) -> Entry {
        if let cached = entries[clipping.id] { return cached }
        let built = Self.makeEntry(clipping)
        entries[clipping.id] = built
        return built
    }

    static func makeEntry(_ clipping: Clipping) -> Entry {
        var others: [(field: MatchField, text: Field)] = []
        if !clipping.isConcealed {
            switch clipping.kind {
            case .text, .code, .json, .richText, .color:
                others.append((.body, Field(head(clipping.payload))))
            case .url:
                // Until a title resolves, the title *is* the URL.
                if clipping.linkTitle != nil { others.append((.link, Field(head(clipping.payload)))) }
            case .file:
                others.append((.path, Field(head(clipping.payload))))
            case .image:
                if let text = clipping.ocrText, !text.isEmpty { others.append((.imageText, Field(head(text)))) }
            }
        }
        let app = clipping.sourceAppName.flatMap { $0.isEmpty ? nil : Field($0) }
        return Entry(title: Field(clipping.displayTitle), others: others, app: app)
    }

    /// The first 64 KB, cut on a scalar boundary.
    static func head(_ text: String) -> String {
        let utf8 = text.utf8
        guard utf8.count > bodyLimit else { return text }
        var end = utf8.index(utf8.startIndex, offsetBy: bodyLimit)
        while end > utf8.startIndex, (utf8[end] & 0xC0) == 0x80 { end = utf8.index(before: end) }
        return String(text[..<end])
    }

    // MARK: Searching

    func search(_ query: ClipQuery, in clippings: [Clipping], now: Date = Date(), calendar: Calendar = .current) -> [ClipHit] {
        let filter = FilterSet(query, now: now, calendar: calendar)
        let words = ClipSearch.words(in: query.text)

        // No text: strict recency, no ranking of any kind. The store keeps
        // `clippings` newest first, so this is a filter and nothing else.
        guard !words.isEmpty else {
            return clippings.compactMap { filter.passes($0) ? ClipHit(clipping: $0) : nil }
        }

        var hits: [ClipHit] = []
        for clipping in clippings where filter.passes(clipping) {
            let entry = entry(for: clipping)
            guard let match = Self.match(entry, words: words) else { continue }
            hits.append(Self.hit(for: clipping, entry: entry, match: match, words: words, now: now))
        }
        hits.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.clipping.lastCopiedAt > rhs.clipping.lastCopiedAt
        }
        return hits
    }

    struct Match {
        var score = 0
        var titleMatched = false
        var appMatched = false
        /// The first word found outside the title, which the snippet shows.
        var outside: (field: MatchField, text: Field, offset: Int, length: Int)?
    }

    /// Every word must appear, literally once folded, in some field. Each word
    /// scores by the best field it appears in.
    static func match(_ entry: Entry, words: [[UInt8]]) -> Match? {
        var match = Match()
        wordLoop: for word in words {
            let title = entry.title.folded
            if let first = title.firstMatch(word) {
                var atWordStart = title.isWordStart(first)
                var from = first + 1
                while !atWordStart, let next = title.firstMatch(word, from: from) {
                    atWordStart = title.isWordStart(next)
                    from = next + 1
                }
                match.score += atWordStart ? 30 : 20
                match.titleMatched = true
                continue
            }
            for other in entry.others {
                if let offset = other.text.folded.firstMatch(word) {
                    match.score += 10
                    if match.outside == nil { match.outside = (other.field, other.text, offset, word.count) }
                    continue wordLoop
                }
            }
            if let app = entry.app, app.folded.firstMatch(word) != nil {
                match.score += 6
                match.appMatched = true
                continue
            }
            return nil
        }
        return match
    }

    /// Recent copies win ties without outranking a better match: at most a
    /// third of a title hit.
    static func recencyBonus(_ date: Date, now: Date) -> Int {
        switch now.timeIntervalSince(date) {
        case ..<3_600: return 10
        case ..<86_400: return 6
        case ..<604_800: return 3
        default: return 0
        }
    }

    private static func hit(for clipping: Clipping, entry: Entry, match: Match, words: [[UInt8]], now: Date) -> ClipHit {
        let titleRanges = ranges(of: words, in: entry.title.folded, original: entry.title.text)

        var snippet: String?
        var snippetRanges: [NSRange] = []
        if let outside = match.outside {
            let line = snippetLine(outside.text, offset: outside.offset, length: outside.length)
            snippet = line
            snippetRanges = ranges(of: words, in: FoldedText(line), original: line)
        }

        let field: MatchField? = match.outside?.field ?? (match.titleMatched ? .title : (match.appMatched ? .app : nil))
        return ClipHit(
            clipping: clipping,
            score: match.score + recencyBonus(clipping.lastCopiedAt, now: now),
            field: field,
            titleRanges: titleRanges,
            snippet: snippet,
            snippetRanges: snippetRanges
        )
    }

    /// Every occurrence of every word, merged where they touch, as UTF-16
    /// ranges in the original text.
    static func ranges(of words: [[UInt8]], in folded: FoldedText, original: String) -> [NSRange] {
        var spans: [Range<Int>] = []
        for word in words {
            for start in folded.allMatches(word) {
                spans.append(start..<(start + word.count))
            }
        }
        guard !spans.isEmpty else { return [] }
        spans.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = [spans[0]]
        for span in spans.dropFirst() {
            if let last = merged.last, span.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
        return merged.map { folded.utf16Range(ofFolded: $0, in: original) }
    }

    /// The line around a match, at most 120 characters, starting a little before
    /// the match so it is never scrolled out of view. "…" marks a cut.
    static func snippetLine(_ field: Field, offset: Int, length: Int) -> String {
        let start = field.folded.originalOffset(offset)
        let end = field.folded.originalOffset(offset + length)
        if let line = field.text.utf8.withContiguousStorageIfAvailable({ snippetLine($0, start: start, end: end) }) {
            return line
        }
        return Array(field.text.utf8).withUnsafeBufferPointer { snippetLine($0, start: start, end: end) }
    }

    private static func snippetLine(_ bytes: UnsafeBufferPointer<UInt8>, start: Int, end: Int) -> String {
        let limit = 120
        let length = max(0, end - start)
        let count = bytes.count
        func isBreak(_ i: Int) -> Bool { bytes[i] == 0x0A || bytes[i] == 0x0D }
        func isContinuation(_ i: Int) -> Bool { i < count && (bytes[i] & 0xC0) == 0x80 }

        var lower = min(start, count)
        while lower > 0, !isBreak(lower - 1), start - lower < 40 { lower -= 1 }
        while lower > 0, isContinuation(lower) { lower -= 1 }
        let cutBefore = lower > 0 && !isBreak(lower - 1)

        var upper = min(start + length, count)
        while upper < count, !isBreak(upper), upper - lower < limit * 4 { upper += 1 }
        while upper < count, isContinuation(upper) { upper += 1 }
        let cutAfter = upper < count && !isBreak(upper)

        var line = String(decoding: UnsafeBufferPointer(rebasing: bytes[lower..<upper]), as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        let budget = limit - (cutBefore ? 1 : 0)
        if line.count > budget {
            line = String(line.prefix(budget - 1)).trimmingCharacters(in: .whitespaces) + "…"
        } else if cutAfter {
            line += "…"
            if line.count > budget { line = String(line.prefix(budget - 1)) + "…" }
        }
        return cutBefore ? "…" + line : line
    }
}

/// Filters grouped by sort: OR within a sort, AND across sorts.
private struct FilterSet {
    var kinds: Set<ClippingKind> = []
    var apps: Set<String> = []
    var days: [DayRange] = []
    var pinnedOnly = false

    let now: Date
    let startOfToday: Date
    let startOfYesterday: Date
    let weekAgo: Date

    init(_ query: ClipQuery, now: Date, calendar: Calendar) {
        self.now = now
        startOfToday = calendar.startOfDay(for: now)
        startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        weekAgo = now.addingTimeInterval(-7 * 86_400)
        pinnedOnly = query.scope == .pinned
        for filter in query.filters {
            switch filter {
            case .kind(let kind):
                kinds.insert(kind)
                // Rich text is text with formatting; asking for text includes it.
                if kind == .text { kinds.insert(.richText) }
            case .app(let bundleID, _): apps.insert(bundleID)
            case .day(let range): days.append(range)
            case .pinned: pinnedOnly = true
            }
        }
    }

    func passes(_ clipping: Clipping) -> Bool {
        if pinnedOnly, !clipping.isPinned { return false }
        if !kinds.isEmpty, !kinds.contains(clipping.kind) { return false }
        if !apps.isEmpty, !apps.contains(clipping.sourceBundleID ?? "") { return false }
        if !days.isEmpty, !days.contains(where: { contains($0, clipping.lastCopiedAt) }) { return false }
        return true
    }

    private func contains(_ range: DayRange, _ date: Date) -> Bool {
        switch range {
        case .today: return date >= startOfToday
        case .yesterday: return date >= startOfYesterday && date < startOfToday
        case .thisWeek: return date >= weekAgo
        }
    }
}
