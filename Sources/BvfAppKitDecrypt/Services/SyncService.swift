import Foundation
import CryptoKit
import BvfAppKit

struct SyncResult: Sendable {
    let filesScanned: Int
    let orphansCleaned: Int     // Matching files deleted from iCloud
    let filesDownloaded: Int    // Placeholder downloads
    let filesCopied: Int        // New or changed files
    let filesVerified: Int      // SHA256 verified
    let filesDeleted: Int       // Permanently deleted from iCloud
    let bytesFreed: Int64
    let errors: [(String, String)]  // Changed to (String, String) for Sendable

    init(filesScanned: Int, orphansCleaned: Int, filesDownloaded: Int,
                filesCopied: Int, filesVerified: Int, filesDeleted: Int,
                bytesFreed: Int64, errors: [(String, String)]) {
        self.filesScanned = filesScanned
        self.orphansCleaned = orphansCleaned
        self.filesDownloaded = filesDownloaded
        self.filesCopied = filesCopied
        self.filesVerified = filesVerified
        self.filesDeleted = filesDeleted
        self.bytesFreed = bytesFreed
        self.errors = errors
    }
}

struct SyncService: Sendable {
    init() {}

    func sync(
        from iCloudSourceURL: URL,
        to localFolderURL: URL,
        progressHandler: (@Sendable (String, Double) async -> Void)? = nil
    ) async throws -> SyncResult {
        var scanned = 0
        var orphansCleaned = 0
        var downloaded = 0
        var copied = 0
        var verified = 0
        var deleted = 0
        var bytesFreed: Int64 = 0
        var errors: [(String, String)] = []

        // Deferred so we only delete from iCloud after the local hash matches.
        var filesToDelete: [URL] = []

        await progressHandler?("Scanning iCloud...", 0.0)

        guard let enumerator = FileManager.default.enumerator(
            at: iCloudSourceURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return SyncResult(filesScanned: 0, orphansCleaned: 0, filesDownloaded: 0,
                            filesCopied: 0, filesVerified: 0, filesDeleted: 0,
                            bytesFreed: 0, errors: [])
        }

        // Convert enumerator to array immediately (required for Swift 6 concurrency)
        let allFiles = enumerator.allObjects as? [URL] ?? []
        let iCloudFiles = allFiles.filter { $0.pathExtension == "bvf" }

        scanned = iCloudFiles.count

        for (index, iCloudFile) in iCloudFiles.enumerated() {
            try Task.checkCancellation()
            let progress = Double(index) / Double(max(iCloudFiles.count, 1))

            guard let relativePath = iCloudFile.path.replacingOccurrences(
                of: iCloudSourceURL.path + "/",
                with: ""
            ).removingPercentEncoding else {
                continue
            }

            await progressHandler?("Processing \(relativePath)", progress)

            var localFile = localFolderURL.appendingPathComponent(relativePath)

            // Detect iCloud bounced filenames (contain a space, e.g., "14.23.45.123 2.txt.bvf")
            // Valid BVF filenames never contain spaces, so any space indicates a bounce.
            // Rewrite to a valid collision-free path so the file is discoverable by FileSearchService.
            if localFile.lastPathComponent.contains(" ") {
                if let rewritten = rewriteBouncedPath(
                    relativePath: relativePath,
                    localFolderURL: localFolderURL
                ) {
                    localFile = rewritten
                } else {
                    errors.append((relativePath, "Bounced filename could not be parsed"))
                    continue
                }
            }

            if !isFileDownloaded(iCloudFile) {
                do {
                    try await downloadPlaceholder(iCloudFile)
                    downloaded += 1
                } catch {
                    errors.append((relativePath, error.localizedDescription))
                    continue
                }
            }

            let iCloudHash: String
            do {
                iCloudHash = try sha256(of: iCloudFile)
            } catch {
                errors.append((relativePath, error.localizedDescription))
                continue
            }

            if FileManager.default.fileExists(atPath: localFile.path) {
                let localHash: String
                do {
                    localHash = try sha256(of: localFile)
                } catch {
                    errors.append((relativePath, error.localizedDescription))
                    continue
                }

                if iCloudHash == localHash {
                    filesToDelete.append(iCloudFile)
                    orphansCleaned += 1
                    continue
                }

                do {
                    try copyFile(from: iCloudFile, to: localFile)
                    copied += 1
                } catch {
                    errors.append((relativePath, error.localizedDescription))
                    continue
                }
            } else {
                do {
                    try copyFile(from: iCloudFile, to: localFile)
                    copied += 1
                } catch {
                    errors.append((relativePath, error.localizedDescription))
                    continue
                }
            }

            // Re-hash after copy to verify integrity before deleting the iCloud copy.
            let localHash: String
            do {
                localHash = try sha256(of: localFile)
            } catch {
                errors.append((relativePath, error.localizedDescription))
                continue
            }

            if iCloudHash == localHash {
                filesToDelete.append(iCloudFile)
                verified += 1
            }
        }

        await progressHandler?("Cleaning up iCloud...", 0.95)

        for iCloudFile in filesToDelete {
            do {
                if let size = try? FileManager.default.attributesOfItem(
                    atPath: iCloudFile.path
                )[.size] as? Int64 {
                    bytesFreed += size
                }

                try await deleteFromiCloud(iCloudFile)
                deleted += 1
            } catch {
            }
        }

        return SyncResult(
            filesScanned: scanned,
            orphansCleaned: orphansCleaned,
            filesDownloaded: downloaded,
            filesCopied: copied,
            filesVerified: verified,
            filesDeleted: deleted,
            bytesFreed: bytesFreed,
            errors: errors
        )
    }

    /// Regex matching the BVF timestamp: HH.mm.ss.SSS
    private static let timestampPattern = try! NSRegularExpression(
        pattern: #"(\d{2}\.\d{2}\.\d{2}\.\d{3})"#
    )

    /// Rewrite an iCloud-bounced relative path to a valid collision-free local path.
    /// Returns nil if the timestamp cannot be extracted from the filename.
    private func rewriteBouncedPath(
        relativePath: String,
        localFolderURL: URL
    ) -> URL? {
        // relativePath is like "2024/06/15/14.23.45.123 2.txt.bvf"
        let components = relativePath.components(separatedBy: "/")
        guard components.count == 4 else { return nil }

        let filename = components[3]

        let range = NSRange(filename.startIndex..., in: filename)
        guard let match = Self.timestampPattern.firstMatch(in: filename, range: range),
              let timestampRange = Range(match.range(at: 1), in: filename) else {
            return nil
        }
        let timestamp = String(filename[timestampRange])

        let datePath = "\(components[0])/\(components[1])/\(components[2])/\(timestamp)"
        guard let date = DateParser.parseDate(from: datePath) else { return nil }

        // After the timestamp, the input might be " 2.txt", " 2", or ".txt 2" — strip the bounce artifact
        // (space + digits) so what remains is just ".<suffix>", then drop the leading dot.
        var remaining = filename
        if remaining.hasSuffix(".bvf") {
            remaining = String(remaining.dropLast(4))
        }
        if let tsRange = remaining.range(of: timestamp) {
            remaining = String(remaining[tsRange.upperBound...])
        }
        let cleaned = remaining.replacingOccurrences(
            of: #"\s+\d*"#, with: "", options: .regularExpression
        )
        let suffix = cleaned.hasPrefix(".") ? String(cleaned.dropFirst()) : ""

        let (url, _) = BvfStore.allocate(
            date: date, suffix: suffix, in: localFolderURL
        )
        return url
    }

    private func isFileDownloaded(_ url: URL) -> Bool {
        var isDownloaded = true

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?

        coordinator.coordinate(
            readingItemAt: url,
            options: [.immediatelyAvailableMetadataOnly],
            error: &error
        ) { url in
            if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
               let status = values.ubiquitousItemDownloadingStatus {
                isDownloaded = (status == .current)
            }
        }

        return isDownloaded
    }

    private func downloadPlaceholder(_ url: URL) async throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)

        let maxWaitTime = BvfAppKitConfig.iCloudDownloadTimeout
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < maxWaitTime {
            if isFileDownloaded(url) {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }

        throw SyncError.downloadTimeout
    }

    private func copyFile(from source: URL, to destination: URL) throws {
        let parentDir = destination.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(
                at: parentDir,
                withIntermediateDirectories: true
            )
        }

        // NSFileCoordinator is required for iCloud reads so the system can stream in the file as needed.
        var copyError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var nsError: NSError?

        coordinator.coordinate(
            readingItemAt: source,
            options: [.withoutChanges],
            error: &nsError
        ) { url in
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }

                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                copyError = error
            }
        }

        if let error = nsError ?? copyError {
            throw error
        }
    }

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func deleteFromiCloud(_ url: URL) async throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var deleteError: Error?
        var nsError: NSError?

        coordinator.coordinate(
            writingItemAt: url,
            options: [.forDeleting],
            error: &nsError
        ) { url in
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                deleteError = error
            }
        }

        if let error = nsError ?? deleteError {
            throw error
        }
    }
}

enum SyncError: LocalizedError {
    case downloadTimeout
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .downloadTimeout:
            return "Download from iCloud timed out"
        case .checksumMismatch:
            return "File integrity verification failed"
        }
    }
}
