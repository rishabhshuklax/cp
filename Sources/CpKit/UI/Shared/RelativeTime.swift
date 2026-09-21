import Foundation

/// When something was copied, in as few characters as the place allows.
///
/// A row has room for `2m`; the hero has room for `Today at 18:04`. Both read
/// off the same clock so they never disagree by a minute.
public enum RelativeTime {

    /// For a row's trailing edge: `40s`, `2m`, `5h`, `18:04` (yesterday), `3d`,
    /// `12 Sep`.
    public static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let interval = max(0, now.timeIntervalSince(date))
        if interval < 60 { return "\(Int(interval))s" }
        if interval < 3_600 { return "\(Int(interval / 60))m" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(interval / 3_600))h" }
        if calendar.isDateInYesterday(date) { return clock(date) }
        if interval < 7 * 86_400 { return "\(Int(interval / 86_400))d" }
        return dayAndMonth.string(from: date)
    }

    /// For the hero and the Library inspector: `40 seconds ago`, `2 min ago`,
    /// `Today at 18:04`, `Yesterday at 18:04`, `3 days ago`.
    public static func long(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let interval = max(0, now.timeIntervalSince(date))
        if interval < 60 { return "\(Int(interval)) seconds ago" }
        if interval < 3_600 {
            let minutes = Int((interval / 60).rounded())
            return minutes == 1 ? "1 min ago" : "\(minutes) min ago"
        }
        if calendar.isDate(date, inSameDayAs: now) { return "Today at \(clock(date))" }
        if calendar.isDateInYesterday(date) { return "Yesterday at \(clock(date))" }
        if interval < 7 * 86_400 {
            let days = Int(interval / 86_400)
            return days == 1 ? "1 day ago" : "\(days) days ago"
        }
        return dayAndMonth.string(from: date) + " at \(clock(date))"
    }

    /// Section labels. Three buckets, because a picker list is a day or two
    /// deep before you start typing.
    public enum Day: String, CaseIterable, Sendable {
        case today = "Today"
        case yesterday = "Yesterday"
        case earlier = "Earlier"
    }

    public static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Day {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }
        return .earlier
    }

    /// Counts down a concealed clipping: `42`.
    public static func secondsLeft(until date: Date, now: Date = Date()) -> Int {
        max(0, Int(date.timeIntervalSince(now).rounded(.up)))
    }

    public static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayAndMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter
    }()
}
