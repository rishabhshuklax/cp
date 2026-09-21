import Foundation

/// Orders the list.
///
/// Recency dominates, as it must — the last thing you copied is overwhelmingly the
/// thing you want. Everything else is a nudge on top, including the one genuinely
/// novel input: what app you are about to paste *into*. You know the frontmost app
/// at invoke time, so in Xcode code ranks up and in Figma colours and images do.
/// It is a soft re-rank, never a filter, so it can be wrong without being annoying.
public struct Ranker: Sendable {

    /// Kinds that get a boost when pasting into a given app, keyed by bundle-ID
    /// fragment so one entry covers `com.apple.dt.Xcode` and friends.
    private static let affinities: [(fragment: String, kinds: Set<ClippingKind>)] = [
        ("xcode", [.code, .file]),
        ("visualstudio", [.code, .file]),
        ("code", [.code, .file]),
        ("terminal", [.code, .file]),
        ("iterm", [.code, .file]),
        ("ghostty", [.code, .file]),
        ("figma", [.color, .image]),
        ("sketch", [.color, .image]),
        ("mail", [.url, .text]),
        ("slack", [.url, .code, .image]),
        ("safari", [.url, .text]),
        ("chrome", [.url, .text]),
        ("notion", [.url, .text, .image]),
        ("obsidian", [.url, .text, .code]),
    ]

    public var targetBundleID: String?
    public var now: Date

    public init(targetBundleID: String? = nil, now: Date = Date()) {
        self.targetBundleID = targetBundleID
        self.now = now
    }

    public func rank(_ clippings: [Clipping], query: SearchQuery) -> [ScoredClipping] {
        let needle = query.text.trimmingCharacters(in: .whitespaces)

        var results: [ScoredClipping] = []
        results.reserveCapacity(clippings.count)

        for clipping in clippings {
            guard query.passesFilters(clipping) else { continue }

            var hit: FuzzyMatch.Hit?
            if !needle.isEmpty {
                // Search the title line first so highlights land somewhere visible,
                // and fall back to the body so a match deep in a file still counts.
                hit = FuzzyMatch.match(needle: needle, haystack: clipping.titleLine)
                if hit == nil {
                    guard let bodyHit = FuzzyMatch.match(needle: needle, haystack: clipping.payload) else { continue }
                    hit = FuzzyMatch.Hit(score: bodyHit.score / 2, indices: [])
                }
            }

            let score = totalScore(for: clipping, searchScore: hit?.score ?? 0)
            results.append(ScoredClipping(clipping: clipping, score: score, highlights: hit?.indices ?? []))
        }

        results.sort { lhs, rhs in
            if lhs.clipping.isPinned != rhs.clipping.isPinned { return lhs.clipping.isPinned }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.clipping.lastCopiedAt > rhs.clipping.lastCopiedAt
        }
        return results
    }

    private func totalScore(for clipping: Clipping, searchScore: Int) -> Int {
        var score = searchScore * 4

        // Recency, as a decaying bonus rather than a sort key, so a strong search
        // hit from yesterday can still out-rank noise from a minute ago.
        let age = now.timeIntervalSince(clipping.lastCopiedAt)
        switch age {
        case ..<300: score += 100
        case ..<3_600: score += 70
        case ..<86_400: score += 40
        case ..<604_800: score += 15
        default: break
        }

        // Copied repeatedly means useful. Capped so a runaway loop can't pin
        // something to the top forever.
        score += min(clipping.copyCount, 10) * 3

        if let target = targetBundleID?.lowercased() {
            for affinity in Self.affinities where target.contains(affinity.fragment) {
                if affinity.kinds.contains(clipping.kind) { score += 25 }
                break
            }
        }
        return score
    }
}

public struct ScoredClipping: Identifiable, Equatable, Sendable {
    public let clipping: Clipping
    public let score: Int
    public let highlights: [Int]

    public var id: UUID { clipping.id }

    public init(clipping: Clipping, score: Int, highlights: [Int] = []) {
        self.clipping = clipping
        self.score = score
        self.highlights = highlights
    }
}
