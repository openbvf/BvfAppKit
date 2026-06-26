import Foundation

/// Manages the per-platform staging directory used during encryption.
public enum StagingManager {
    /// Per-platform staging root: app's Documents on iOS, Application Support on macOS.
    public static var directoryURL: URL {
        let base: URL
        #if os(iOS)
        base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        #else
        base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        #endif
        return base.appendingPathComponent("staging")
    }

    /// (date, suffix) parsed from a staged file's path. Nil for any non-canonical shape.
    package struct StagedFile {
        let date: Date
        let suffix: String
    }

    /// Inverse of `stagingPath`. Validates that `fileURL` is a canonical staged file
    /// rooted at `stagingRoot` and extracts its date and suffix.
    /// Canonical staging shape: `{stagingRoot}/yyyy/MM/dd/HH.mm.ss.SSS.{suffix}.{uuid}.bvf`
    /// — 6 dot-segments after stripping `.bvf`.
    package static func parseStagingPath(_ fileURL: URL, in stagingRoot: URL) -> StagedFile? {
        guard let parts = BvfStore.splitDottedBvfFilename(fileURL.lastPathComponent),
              parts.count == 6,
              !parts[4].isEmpty,
              let relativePath = fileURL.path.components(separatedBy: stagingRoot.path + "/").last
        else { return nil }
        let withoutBvf = String(relativePath.dropLast(".bvf".count))
        guard let date = DateParser.parseDate(from: withoutBvf) else { return nil }
        return StagedFile(date: date, suffix: parts[4])
    }

    /// Move orphaned .bvf files from staging to iCloud with collision detection.
    /// No-op when destinationURL is nil or the staging directory does not exist.
    /// `stagingURL` defaults to the shared staging directory; tests override.
    public static func recoverOrphanedFiles(from stagingURL: URL = directoryURL, to destinationURL: URL?) {
        guard let destinationURL else { return }

        guard FileManager.default.fileExists(atPath: stagingURL.path) else {
            return
        }

        let enumerator = FileManager.default.enumerator(
            at: stagingURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "bvf" else { continue }

            // Skip header-only files — no encrypted data to recover
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
            if fileSize <= CryptoService.headerSize {
                try? FileManager.default.removeItem(at: fileURL)
                cleanupEmptyDirectories(above: fileURL, root: stagingURL)
                continue
            }

            guard let parsed = parseStagingPath(fileURL, in: stagingURL) else { continue }

            do {
                try BvfStore.commit(staged: fileURL, date: parsed.date, suffix: parsed.suffix, in: destinationURL)
                cleanupEmptyDirectories(above: fileURL, root: stagingURL)
            } catch {
            }
        }

        sweepEmptySubdirectories(of: stagingURL)
    }

    /// Stage, encrypt, then commit to a collision-free destination.
    /// Allocation happens after encryption succeeds — no race window at move-time.
    package static func stageAndCommit(
        date: Date,
        suffix: String,
        in folderURL: URL,
        stagingURL: URL = directoryURL,
        encrypt: (URL) throws -> Void
    ) throws -> (url: URL, adjustedDate: Date) {
        let stagingFile = try stage(date: date, suffix: suffix, stagingURL: stagingURL, encrypt: encrypt)
        return try BvfStore.commit(staged: stagingFile, date: date, suffix: suffix, in: folderURL)
    }

    /// Stage, encrypt, then replace an existing destination file atomically.
    package static func stageAndReplace(
        destination: URL,
        suffix: String,
        stagingURL: URL = directoryURL,
        encrypt: (URL) throws -> Void
    ) throws {
        let stagingFile = try stage(date: Date(), suffix: suffix, stagingURL: stagingURL, encrypt: encrypt)
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: stagingFile)
    }

    /// Canonical staging filename: `{filePathString}.{suffix}.{uuid}.bvf`.
    /// Single source of truth for the staging shape used by `stage` and `PushEncryptionContext`.
    package static func stagingPath(date: Date, suffix: String, in stagingURL: URL = directoryURL) -> URL {
        stagingURL
            .appendingPathComponent(date.filePathString)
            .appendingPathExtension(suffix)
            .appendingPathExtension(UUID().uuidString)
            .appendingPathExtension("bvf")
    }

    /// Encrypts to a temp file in `stagingURL` and returns that file's URL.
    /// The caller is responsible for moving or replacing the staged file.
    package static func stage(
        date: Date,
        suffix: String,
        stagingURL: URL = directoryURL,
        encrypt: (URL) throws -> Void
    ) throws -> URL {
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        let stagingFile = stagingPath(date: date, suffix: suffix, in: stagingURL)

        try FileManager.default.createDirectory(at: stagingFile.deletingLastPathComponent(), withIntermediateDirectories: true)

        do {
            try encrypt(stagingFile)
        } catch {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: stagingFile.path)[.size] as? Int) ?? 0
            if fileSize <= CryptoService.headerSize {
                try? FileManager.default.removeItem(at: stagingFile)
            }
            throw error
        }

        return stagingFile
    }

    /// Walk upward from `fileURL`, removing each parent directory that is empty,
    /// stopping at (and not including) `root`.
    static func cleanupEmptyDirectories(above fileURL: URL, root: URL) {
        var dir = fileURL.deletingLastPathComponent()
        let rootPath = root.path
        while dir.path != rootPath, dir.path.hasPrefix(rootPath) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            guard contents.isEmpty else { break }
            try? FileManager.default.removeItem(at: dir)
            dir = dir.deletingLastPathComponent()
        }
    }

    private static func sweepEmptySubdirectories(of root: URL) {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return }
        for child in children {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            sweepEmptySubdirectories(of: child)
            let remaining = (try? FileManager.default.contentsOfDirectory(atPath: child.path)) ?? []
            if remaining.isEmpty {
                try? FileManager.default.removeItem(at: child)
            }
        }
    }
}
