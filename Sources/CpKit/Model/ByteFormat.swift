import Foundation

/// Byte counts for people: `1.2 KB`, and back again from `20k` or `2mb`.
public enum ByteFormat {
    public static func short(_ bytes: Int) -> String {
        if bytes < 1_024 { return "\(bytes) B" }
        if bytes < 1_024 * 1_024 { return String(format: "%.1f KB", Double(bytes) / 1_024) }
        return String(format: "%.1f MB", Double(bytes) / (1_024 * 1_024))
    }

    /// Parses `1kb`, `20k`, `2mb`, `512` into a byte count. Anything that is not a
    /// finite, non-negative size that fits in an `Int` is `nil` — `1e30k` used to
    /// trap on the conversion.
    public static func parse(_ input: String) -> Int? {
        let trimmed = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let multipliers: [(suffix: String, factor: Double)] = [
            ("mb", 1_024 * 1_024), ("m", 1_024 * 1_024),
            ("kb", 1_024), ("k", 1_024),
            ("b", 1),
        ]
        for (suffix, factor) in multipliers where trimmed.hasSuffix(suffix) {
            guard let value = Double(trimmed.dropLast(suffix.count)) else { return nil }
            return bytes(value * factor)
        }
        guard let value = Double(trimmed) else { return nil }
        return bytes(value)
    }

    private static func bytes(_ value: Double) -> Int? {
        // `Double(Int.max)` rounds up to 2^63, so `<` is the check that keeps the
        // conversion below from trapping.
        guard value.isFinite, value >= 0, value < Double(Int.max) else { return nil }
        return Int(value)
    }
}
