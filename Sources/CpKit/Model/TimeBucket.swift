import Foundation

/// Section headers for the picker list.
///
/// A flat reverse-chronological list gives "the thing I copied during that call an
/// hour ago" no handle to grab. Coarse, human buckets give it one, and they cost a
/// single comparison per row.
public enum TimeBucket: Int, CaseIterable, Sendable {
    case pinned
    case now          // < 5 minutes
    case earlierToday
    case yesterday
    case thisWeek
    case older

    public var title: String {
        switch self {
        case .pinned: return "Pinned"
        case .now: return "Now"
        case .earlierToday: return "Earlier today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "This week"
        case .older: return "Older"
        }
    }

    public static func bucket(
        for clipping: Clipping,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TimeBucket {
        if clipping.isPinned { return .pinned }

        let date = clipping.lastCopiedAt
        let interval = now.timeIntervalSince(date)

        if interval < 300 { return .now }
        if calendar.isDateInToday(date) { return .earlierToday }
        if calendar.isDateInYesterday(date) { return .yesterday }
        if interval < 7 * 24 * 3600 { return .thisWeek }
        return .older
    }

    /// Compact relative stamp for the row's trailing edge: `2m`, `4h`, `3d`.
    public static func relativeStamp(for date: Date, now: Date = Date()) -> String {
        let interval = max(0, now.timeIntervalSince(date))
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86_400 { return "\(Int(interval / 3600))h" }
        if interval < 7 * 86_400 { return "\(Int(interval / 86_400))d" }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }
}
