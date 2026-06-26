import Foundation

/// Inclusive date range bounded by two `Date`s.
public struct DateRange: Sendable {
    /// First included date.
    public let start: Date
    /// The last included day (start-of-day). For queries, use `BrowseViewModelBase.queryRange()`.
    public let end: Date

    /// Create a range. `start` and `end` are both inclusive.
    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

/// Named, relative date-range presets exposed in the UI.
public enum DateRangePreset: CaseIterable, Hashable, Sendable {
    case today
    case yesterday
    case thisWeek
    case last7Days
    case lastWeek
    case thisMonth
    case last30Days
    case lastMonth
    case thisYear
    case lastYear
    case forever

    /// Human-readable label for the preset.
    public var displayName: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "This Week"
        case .lastWeek: return "Last Week"
        case .thisMonth: return "This Month"
        case .lastMonth: return "Last Month"
        case .thisYear: return "This Year"
        case .lastYear: return "Last Year"
        case .last7Days: return "Last 7 Days"
        case .last30Days: return "Last 30 Days"
        case .forever: return "Forever"
        }
    }

    /// Resolve the preset to a concrete `DateRange` relative to `now` in the given calendar.
    public func dateRange(calendar: Calendar = .current, now: Date = Date()) -> DateRange {
        switch self {
        case .today:
            return dayRange(for: now, calendar: calendar)

        case .yesterday:
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
            return dayRange(for: yesterday, calendar: calendar)

        case .thisWeek:
            return weekRange(for: now, calendar: calendar)

        case .lastWeek:
            let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: now)!
            return weekRange(for: lastWeek, calendar: calendar)

        case .thisMonth:
            return monthRange(for: now, calendar: calendar)

        case .lastMonth:
            let lastMonth = calendar.date(byAdding: .month, value: -1, to: now)!
            return monthRange(for: lastMonth, calendar: calendar)

        case .last7Days:
            let start = calendar.date(byAdding: .day, value: -7, to: now)!
            let endDate = calendar.startOfDay(for: now)
            return DateRange(start: start, end: endDate)

        case .last30Days:
            let start = calendar.date(byAdding: .day, value: -30, to: now)!
            let endDate = calendar.startOfDay(for: now)
            return DateRange(start: start, end: endDate)

        case .thisYear:
            return yearRange(for: now, calendar: calendar)

        case .lastYear:
            let lastYear = calendar.date(byAdding: .year, value: -1, to: now)!
            return yearRange(for: lastYear, calendar: calendar)

        case .forever:
            let epochStart = Date(timeIntervalSince1970: 0)
            let endDate = calendar.startOfDay(for: now)
            return DateRange(start: epochStart, end: endDate)
        }
    }

    private func dayRange(for date: Date, calendar: Calendar) -> DateRange {
        let start = calendar.startOfDay(for: date)
        return DateRange(start: start, end: start)
    }

    private func weekRange(for date: Date, calendar: Calendar) -> DateRange {
        let interval = calendar.dateInterval(of: .weekOfYear, for: date)!
        let end = calendar.date(byAdding: .day, value: -1, to: interval.end)!
        return DateRange(start: interval.start, end: end)
    }

    private func monthRange(for date: Date, calendar: Calendar) -> DateRange {
        let interval = calendar.dateInterval(of: .month, for: date)!
        let end = calendar.date(byAdding: .day, value: -1, to: interval.end)!
        return DateRange(start: interval.start, end: end)
    }

    private func yearRange(for date: Date, calendar: Calendar) -> DateRange {
        let interval = calendar.dateInterval(of: .year, for: date)!
        let end = calendar.date(byAdding: .day, value: -1, to: interval.end)!
        return DateRange(start: interval.start, end: end)
    }
}
