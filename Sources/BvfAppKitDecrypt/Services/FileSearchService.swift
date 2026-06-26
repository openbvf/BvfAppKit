import Foundation
import BvfAppKit

/// Finds and enumerates BVF files within a yyyy/MM/dd directory structure.
enum FileSearchService {

    /// Asynchronously find all BVF files in `rootDirectory` whose timestamp falls in `[dateRange.start, dateRange.end)`.
    static func findMatchingFiles(
        in rootDirectory: URL,
        dateRange: DateRange
    ) async -> FileSearchResult {
        let fileManager = FileManager.default
        var matchingFiles: [URL] = []
        var totalFilesScanned = 0
        var bvFilesFound = 0
        var dateParseFailures = 0

        for datePath in generateDatePaths(from: dateRange.start, to: dateRange.end) {
            let dateDirectoryURL = rootDirectory.appendingPathComponent(datePath)

            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: dateDirectoryURL.path, isDirectory: &isDir),
                  isDir.boolValue else {
                continue
            }

            guard let enumerator = fileManager.enumerator(
                at: dateDirectoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else {
                continue
            }

            while let fileURL = enumerator.nextObject() as? URL {
                totalFilesScanned += 1

                if totalFilesScanned % 1000 == 0 {
                    await Task.yield()
                }

                // Broken symlinks and permission errors can throw here; skip rather than crash.
                do {
                    let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                    guard resourceValues.isRegularFile == true else { continue }
                } catch {
                    continue
                }

                guard fileURL.pathExtension == "bvf" else { continue }
                bvFilesFound += 1

                guard let fileDate = fileURL.bvfDate() else {
                    dateParseFailures += 1
                    continue
                }

                if fileDate >= dateRange.start && fileDate < dateRange.end {
                    matchingFiles.append(fileURL)
                }
            }
        }

        return FileSearchResult(
            matchingFiles: matchingFiles,
            totalScanned: totalFilesScanned,
            bvFound: bvFilesFound,
            dateFailures: dateParseFailures
        )
    }

    /// Generate `yyyy/MM/dd` directory paths for every UTC day intersecting `[startDate, endDate]`.
    private static func generateDatePaths(from startDate: Date, to endDate: Date) -> [String] {
        let calendar = Calendar.utc
        var paths: [String] = []

        guard var current = calendar.date(from: calendar.dateComponents([.year, .month, .day], from: startDate)),
              let final = calendar.date(from: calendar.dateComponents([.year, .month, .day], from: endDate)) else {
            return []
        }

        while current <= final {
            let c = calendar.dateComponents([.year, .month, .day], from: current)
            paths.append(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))

            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }

        return paths
    }
}


struct FileSearchResult: Sendable {
    let matchingFiles: [URL]
    let totalScanned: Int
    let bvFound: Int
    let dateFailures: Int

    var isEmpty: Bool {
        matchingFiles.isEmpty
    }

    var summary: String {
        if isEmpty {
            return "No matching files found"
        } else {
            return "Found \(matchingFiles.count) files"
        }
    }
}
