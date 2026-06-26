import Foundation

/// File-store primitives for allocating, writing, and moving `.bvf` files in canonical layout.
public enum BvfStore {
    /// Suffix applied when callers pass an empty string.
    public static let defaultSuffix = "sth"

    /// Allocate a collision-free destination path without moving anything.
    /// An empty `suffix` is replaced with `defaultSuffix`.
    public static func allocate(
        date: Date,
        suffix: String,
        in folderURL: URL,
        reserved: Set<String> = []
    ) -> (url: URL, adjustedDate: Date) {
        let effectiveSuffix = suffix.isEmpty ? defaultSuffix : suffix
        var adjustedDate = date
        var path = folderURL
            .appendingPathComponent(adjustedDate.filePathString)
            .appendingPathExtension(effectiveSuffix)
            .appendingPathExtension("bvf")

        while FileManager.default.fileExists(atPath: path.path)
              || reserved.contains(path.path) {
            adjustedDate = adjustedDate.addingTimeInterval(0.001)
            path = folderURL
                .appendingPathComponent(adjustedDate.filePathString)
                .appendingPathExtension(effectiveSuffix)
                .appendingPathExtension("bvf")
        }
        return (path, adjustedDate)
    }

    /// Move a staged file to a pre-allocated destination, creating parent directories.
    @discardableResult
    public static func move(staged: URL, to destination: URL) throws -> URL {
        let dir = destination.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try FileManager.default.moveItem(at: staged, to: destination)
        return destination
    }

    /// Allocate a collision-free path then move `staged` there atomically.
    /// Wraps `folderURL.startAccessingSecurityScopedResource()` internally; idempotent
    /// when callers also wrap.
    @discardableResult
    public static func commit(
        staged: URL,
        date: Date,
        suffix: String,
        in folderURL: URL,
        reserved: Set<String> = []
    ) throws -> (url: URL, adjustedDate: Date) {
        let didStartAccess = folderURL.startAccessingSecurityScopedResource()
        defer { if didStartAccess { folderURL.stopAccessingSecurityScopedResource() } }

        let (destination, adjustedDate) = allocate(date: date, suffix: suffix, in: folderURL, reserved: reserved)
        try move(staged: staged, to: destination)
        return (destination, adjustedDate)
    }

    /// Strip the trailing `.bvf` from `filename`, split on `.`, and require the leading 4
    /// segments to be non-empty and all-numeric. Returns the dot-components on success,
    /// nil on any deviation. Shared by `deriveSuffix` (committed shape, 5 segments) and
    /// `StagingManager.parseStagingPath` (staging shape, 6 segments).
    package static func splitDottedBvfFilename(_ filename: String) -> [String]? {
        guard filename.hasSuffix(".bvf") else { return nil }
        let withoutBvf = String(filename.dropLast(".bvf".count))
        let parts = withoutBvf.components(separatedBy: ".")
        guard parts.count >= 4 else { return nil }
        for part in parts.prefix(4) {
            guard !part.isEmpty, part.allSatisfy(\.isNumber) else { return nil }
        }
        return parts
    }

    /// Parse the suffix from a store-canonical URL (`yyyy/MM/dd/HH.mm.ss.SSS.{suffix}.bvf`).
    /// Requires exactly 5 dot-segments where the first four are numeric and the suffix is non-empty.
    /// Throws `BvfStoreError.malformedPath` for any non-canonical URL.
    /// Foundation's `pathExtension` is not used.
    public static func deriveSuffix(from url: URL) throws -> String {
        guard let parts = splitDottedBvfFilename(url.lastPathComponent),
              parts.count == 5,
              !parts[4].isEmpty
        else { throw BvfStoreError.malformedPath(url) }
        return parts[4]
    }

    /// Encrypts data and writes to a timestamped file path with collision detection.
    /// `stagingURL` defaults to the shared staging directory; callers like transcription
    /// can override to route through a separate area where orphans aren't auto-recovered.
    public static func write(
        data: Data,
        to folderURL: URL,
        publicKeyURL: URL,
        date: Date = Date(),
        suffix: String,
        stagingURL: URL = StagingManager.directoryURL
    ) async throws -> URL {
        let crypto = CryptoService()
        let (url, _) = try StagingManager.stageAndCommit(date: date, suffix: suffix, in: folderURL, stagingURL: stagingURL) {
            try crypto.encryptDataToFile(plaintext: data, publicKeyURL: publicKeyURL, outputPath: $0)
        }
        return url
    }

    /// Re-encrypts data to an existing URL, preserving the original on failure.
    public static func rewrite(data: Data, to url: URL, publicKeyURL: URL) throws {
        let suffix = try deriveSuffix(from: url)
        let crypto = CryptoService()
        try StagingManager.stageAndReplace(destination: url, suffix: suffix) {
            try crypto.encryptDataToFile(plaintext: data, publicKeyURL: publicKeyURL, outputPath: $0)
        }
    }

    /// Moves an encrypted file to a new timestamped path with collision detection.
    public static func moveFile(
        from sourceURL: URL,
        to targetDate: Date,
        in folderURL: URL
    ) throws -> (url: URL, adjustedDate: Date) {
        let suffix = try deriveSuffix(from: sourceURL)
        return try commit(staged: sourceURL, date: targetDate, suffix: suffix, in: folderURL)
    }
}

/// Errors thrown by `BvfStore` path parsing.
public enum BvfStoreError: Error {
    case malformedPath(URL)
}

