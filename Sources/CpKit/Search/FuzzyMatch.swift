import Foundation

/// Subsequence matching with the usual quality bonuses — consecutive runs and
/// word-boundary starts score higher, so `psv` ranks `PullRequestView` above a
/// file that merely happens to contain p, s and v in order.
///
/// Returns `nil` for a miss so callers can filter and rank in one pass, and hands
/// back matched indices so the row can highlight them.
public enum FuzzyMatch {

    public struct Hit: Equatable, Sendable {
        public let score: Int
        /// Offsets into the *haystack* of each matched character.
        public let indices: [Int]
    }

    private static let consecutiveBonus = 8
    private static let boundaryBonus = 12
    private static let leadingPenalty = 1
    private static let maxHaystack = 4_096

    public static func match(needle: String, haystack: String) -> Hit? {
        guard !needle.isEmpty else { return Hit(score: 0, indices: []) }

        let needleChars = Array(needle.lowercased())
        let haystackChars = Array(haystack.prefix(maxHaystack).lowercased())
        guard needleChars.count <= haystackChars.count else { return nil }

        var indices: [Int] = []
        indices.reserveCapacity(needleChars.count)

        var score = 0
        var needleIndex = 0
        var previousMatch: Int?

        for (position, character) in haystackChars.enumerated() {
            guard needleIndex < needleChars.count else { break }
            guard character == needleChars[needleIndex] else { continue }

            if let previous = previousMatch, position == previous + 1 {
                score += consecutiveBonus
            }
            if isWordBoundary(haystackChars, at: position) {
                score += boundaryBonus
            }
            if previousMatch == nil {
                // Prefer matches that start early in the string.
                score -= min(position, 20) * leadingPenalty
            }

            indices.append(position)
            previousMatch = position
            needleIndex += 1
        }

        guard needleIndex == needleChars.count else { return nil }
        // Shorter haystacks with the same hits are better matches.
        score += max(0, 40 - haystackChars.count / 8)
        return Hit(score: score, indices: indices)
    }

    private static func isWordBoundary(_ characters: [Character], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        return !previous.isLetter && !previous.isNumber
    }
}
