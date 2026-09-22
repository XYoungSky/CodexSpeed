import Foundation

/// Today and the previous 13 UTC calendar days, including resumed old tasks.
public enum LogWindow {
    public static func cutoff(now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(byAdding: .day, value: -13, to: calendar.startOfDay(for: now))!
    }

    public static func activeCutoff(now: Date = Date()) -> Date { now.addingTimeInterval(-24 * 60 * 60) }

    public static func includes(_ url: URL, cutoff: Date) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
        guard values.isRegularFile == true, let modified = values.contentModificationDate else { return false }
        return modified >= cutoff
    }
}
