import Foundation
import os

/// Case- and diacritic-insensitive text, as UTF-8 bytes, that remembers where
/// each byte came from.
///
/// Search compares bytes (`memmem`), so matching a 64 KB body costs a few
/// microseconds. The catch with folding is that it changes lengths — `É` is two
/// bytes and folds to one, a decomposed `é` drops its accent entirely — so a
/// match position in the folded text is not a position in the original. The
/// anchors record the few places where lengths diverge, which is what lets a
/// highlight land on the letters actually typed instead of drifting sideways.
struct FoldedText: Sendable {
    let bytes: [UInt8]
    /// Plain ASCII: folded, UTF-8 and UTF-16 offsets are all the same number.
    let isASCII: Bool
    /// After each scalar whose folded length differs from its original length:
    /// the folded and original offsets just past it.
    private let anchors: [Anchor]

    struct Anchor: Sendable {
        let folded: Int
        let original: Int
    }

    init<S: StringProtocol>(_ text: S) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)

        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            for byte in text.utf8 {
                bytes.append(byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte)
            }
            self.bytes = bytes
            self.isASCII = true
            self.anchors = []
            return
        }

        var anchors: [Anchor] = []
        var original = 0
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value < 0x80 {
                let byte = UInt8(value)
                bytes.append(byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte)
                original += 1
                continue
            }
            let before = bytes.count
            Folding.append(scalar, to: &bytes)
            let width = UTF8.width(scalar)
            original += width
            if bytes.count - before != width {
                anchors.append(Anchor(folded: bytes.count, original: original))
            }
        }
        self.bytes = bytes
        self.isASCII = false
        self.anchors = anchors
    }

    var isEmpty: Bool { bytes.isEmpty }

    /// The original UTF-8 offset for a folded one. Inside a scalar that folded to
    /// a different length it lands somewhere in that scalar; callers round to
    /// scalar boundaries against the original bytes.
    func originalOffset(_ folded: Int) -> Int {
        guard !anchors.isEmpty else { return folded }
        var low = 0
        var high = anchors.count
        while low < high {
            let mid = (low + high) / 2
            if anchors[mid].folded <= folded { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return folded }
        let anchor = anchors[low - 1]
        return anchor.original + (folded - anchor.folded)
    }

    // MARK: - Matching

    /// Offset of the first occurrence of `needle` at or after `from`.
    func firstMatch(_ needle: [UInt8], from: Int = 0) -> Int? {
        guard !needle.isEmpty, from < bytes.count, needle.count <= bytes.count - from else { return nil }
        return bytes.withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { pin in
                guard let base = hay.baseAddress, let pinBase = pin.baseAddress,
                      let found = memmem(base + from, hay.count - from, pinBase, pin.count) else { return nil }
                return base.distance(to: found.assumingMemoryBound(to: UInt8.self))
            }
        }
    }

    /// Non-overlapping occurrences, at most `limit` of them.
    func allMatches(_ needle: [UInt8], limit: Int = .max) -> [Int] {
        guard !needle.isEmpty, needle.count <= bytes.count else { return [] }
        var result: [Int] = []
        bytes.withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { pin in
                guard let base = hay.baseAddress, let pinBase = pin.baseAddress else { return }
                var from = 0
                while result.count < limit, from + pin.count <= hay.count,
                      let found = memmem(base + from, hay.count - from, pinBase, pin.count) {
                    let offset = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
                    result.append(offset)
                    from = offset + pin.count
                }
            }
        }
        return result
    }

    /// Whether an occurrence starts a word: nothing but a separator before it.
    func isWordStart(_ offset: Int) -> Bool {
        guard offset > 0 else { return true }
        let previous = bytes[offset - 1]
        let isWordByte = (previous >= 0x30 && previous <= 0x39) || (previous >= 0x61 && previous <= 0x7A)
            || previous == 0x5F || previous >= 0x80
        return !isWordByte
    }

    // MARK: - Mapping back

    /// The UTF-16 range in `original` covering folded bytes `range`, rounded out
    /// to whole scalars. `original` must be the text this was folded from.
    func utf16Range(ofFolded range: Range<Int>, in original: String) -> NSRange {
        if isASCII {
            return NSRange(location: range.lowerBound, length: range.count)
        }
        let utf8 = original.utf8
        let count = utf8.count
        var start = min(originalOffset(range.lowerBound), count)
        var end = min(max(originalOffset(range.upperBound), start), count)
        func isContinuation(_ offset: Int) -> Bool {
            offset < count && (utf8[utf8.index(utf8.startIndex, offsetBy: offset)] & 0xC0) == 0x80
        }
        while start > 0, isContinuation(start) { start -= 1 }
        while end < count, isContinuation(end) { end += 1 }
        let lower = utf8.index(utf8.startIndex, offsetBy: start)
        let upper = utf8.index(utf8.startIndex, offsetBy: end)
        return NSRange(lower..<upper, in: original)
    }
}

/// Folding one scalar at a time, so query and text fold identically and every
/// output byte can be traced to the scalar it came from.
enum Folding {

    static func append(_ scalar: Unicode.Scalar, to bytes: inout [UInt8]) {
        let value = scalar.value
        // Punctuation, symbols, CJK, Hangul and emoji have no case and no accents.
        if (0x2000...0x2BFF).contains(value) || (0x3000...0xD7FF).contains(value)
            || (0xE000...0xF8FF).contains(value) || value >= 0x1F000 {
            UTF8.encode(scalar) { bytes.append($0) }
            return
        }
        // A decomposed accent. Foundation drops these when folding a whole string,
        // but not when handed one alone.
        if scalar.properties.generalCategory == .nonspacingMark { return }
        bytes.append(contentsOf: folded(scalar))
    }

    private static let cache = OSAllocatedUnfairLock(initialState: [UInt32: [UInt8]]())

    private static func folded(_ scalar: Unicode.Scalar) -> [UInt8] {
        if let hit = cache.withLock({ $0[scalar.value] }) { return hit }
        let folded = String(Character(scalar)).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var result: [UInt8] = []
        for piece in folded.unicodeScalars where piece.properties.generalCategory != .nonspacingMark {
            UTF8.encode(piece) { result.append($0) }
        }
        let finished = result
        cache.withLock { $0[scalar.value] = finished }
        return finished
    }
}
