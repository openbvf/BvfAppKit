import Foundation

enum BrowseFileOps {
    struct DeleteResult: Sendable {
        let deletedDates: Set<Date>
        let failures: [FileFailure]
    }

    /// Delete files from disk.
    static func deleteFiles(
        at dates: Set<Date>,
        filesByDate: [Date: URL],
        folderURL: URL
    ) -> DeleteResult {
        let didStartAccess = folderURL.startAccessingSecurityScopedResource()
        defer { if didStartAccess { folderURL.stopAccessingSecurityScopedResource() } }

        var deletedDates = Set<Date>()
        var failures: [FileFailure] = []

        for date in dates {
            guard let url = filesByDate[date] else {
                failures.append(FileFailure(
                    url: folderURL.appendingPathComponent(date.filePathString),
                    errorDescription: "missing — no file recorded for this entry"
                ))
                continue
            }

            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                failures.append(FileFailure(url: url, errorDescription: error.localizedDescription))
                continue
            }

            deletedDates.insert(date)
        }

        return DeleteResult(deletedDates: deletedDates, failures: failures)
    }

    struct MoveResult: Sendable {
        struct Move: Sendable {
            let oldDate: Date
            let newDate: Date
            let newURL: URL
        }
        let moves: [Move]
        let failures: [FileFailure]
    }

    /// Move files to a new date.
    static func changeDates(
        for dates: Set<Date>,
        to newDate: Date,
        filesByDate: [Date: URL],
        folderURL: URL
    ) -> MoveResult {
        let didStartAccess = folderURL.startAccessingSecurityScopedResource()
        defer { if didStartAccess { folderURL.stopAccessingSecurityScopedResource() } }

        var moves: [MoveResult.Move] = []
        var failures: [FileFailure] = []

        for oldDate in dates {
            guard let sourceURL = filesByDate[oldDate] else {
                failures.append(FileFailure(
                    url: folderURL.appendingPathComponent(oldDate.filePathString),
                    errorDescription: "missing — no file recorded for this entry"
                ))
                continue
            }

            do {
                let (newURL, actualDate) = try BvfStore.moveFile(from: sourceURL, to: newDate, in: folderURL)
                moves.append(MoveResult.Move(oldDate: oldDate, newDate: actualDate, newURL: newURL))
            } catch {
                failures.append(FileFailure(url: sourceURL, errorDescription: error.localizedDescription))
            }
        }

        return MoveResult(moves: moves, failures: failures)
    }
}
