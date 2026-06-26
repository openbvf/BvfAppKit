import Foundation

/// Groups dates by day and returns sorted groups
public func groupDatesByDay(_ dates: [Date]) -> [(day: Date, dates: [Date])] {
    let calendar = Calendar.current
    let grouped = Dictionary(grouping: dates) { date in
        calendar.startOfDay(for: date)
    }
    return grouped.map { day, dates in
        (day: day, dates: dates.sorted(by: <))
    }.sorted { $0.day < $1.day }
}
