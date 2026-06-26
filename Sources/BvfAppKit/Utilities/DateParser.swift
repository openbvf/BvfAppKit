import Foundation

/// Utility for parsing dates from file paths and date strings
public struct DateParser {

    /// Parse a date from a file path string (yyyy/MM/dd/HH.mm.ss.SSS)
    public static func parseDate(from path: String) -> Date? {
        let components = path.components(separatedBy: "/")
        guard components.count == 4 else { return nil }

        let timeParts = components[3].components(separatedBy: ".")
        guard timeParts.count >= 4,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2]),
              let hour = Int(timeParts[0]),
              let minute = Int(timeParts[1]),
              let second = Int(timeParts[2]),
              let millisecond = Int(timeParts[3]) else {
            return nil
        }

        var dc = DateComponents()
        dc.year = year
        dc.month = month
        dc.day = day
        dc.hour = hour
        dc.minute = minute
        dc.second = second
        dc.nanosecond = millisecond * 1_000_000
        return Calendar.utc.date(from: dc)
    }

    /// Convert a file path to a date, with fallback handling
    public static func pathToDate(path: String) -> Date {
        return parseDate(from: path) ?? Date.distantPast
    }

}

extension URL {
    /// Extract date from BVF file path (yyyy/MM/dd/HH.mm.ss.SSS.bvf)
    public func bvfDate() -> Date? {
        let pathComponents = self.pathComponents
        guard pathComponents.count >= 4 else { return nil }

        let dayIndex = pathComponents.count - 2
        let monthIndex = pathComponents.count - 3
        let yearIndex = pathComponents.count - 4
        let filename = self.deletingPathExtension().lastPathComponent

        let pathString = "\(pathComponents[yearIndex])/\(pathComponents[monthIndex])/\(pathComponents[dayIndex])/\(filename)"
        return DateParser.parseDate(from: pathString)
    }
}
