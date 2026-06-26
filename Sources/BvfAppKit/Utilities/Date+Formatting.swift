import Foundation

/// Adds a UTC calendar suitable for file timestamp work.
public extension Calendar {
    /// A UTC calendar for timestamp operations.
    /// Use this for all file path generation and parsing to ensure consistent UTC-based timestamps.
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}

extension Date {
    /// Thread-safe UTC file path string: yyyy/MM/dd/HH.mm.ss.SSS
    public var filePathString: String {
        let c = Calendar.utc.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: self
        )
        let ms = ((c.nanosecond ?? 0) + 500_000) / 1_000_000
        return String(
            format: "%04d/%02d/%02d/%02d.%02d.%02d.%03d",
            c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!, ms
        )
    }


    /// Locale-formatted hour and minute string.
    public var timeString: String {
        formatted(.dateTime.hour().minute())
    }

    /// Locale-formatted weekday, month, day, and year string.
    public var dayWithWeekdayString: String {
        formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }

    /// Returns a human-readable relative time string (e.g., "just now", "5 min ago", "2 hours ago")
    public func relativeTimeString() -> String {
        let elapsed = abs(timeIntervalSinceNow)
        let minutes = Int(elapsed / 60)

        if minutes < 1 {
            return "just now"
        } else if minutes == 1 {
            return "1 min ago"
        } else if minutes < 60 {
            return "\(minutes) min ago"
        } else {
            let hours = minutes / 60
            if hours >= 4 { return "a while ago" }
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }
    }
}

extension Int64 {
    /// Returns a formatted byte count string (e.g., "1.5 MB", "500 KB")
    public func formattedByteCount(style: ByteCountFormatter.CountStyle = .file) -> String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: style)
    }
}
