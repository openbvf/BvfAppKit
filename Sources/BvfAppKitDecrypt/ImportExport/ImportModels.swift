import Foundation

struct ImportedFileInfo: Sendable {
    let sourceURL: URL
    let date: Date
    let relativePath: String
    let wasProcessed: Bool
    let sourceContentHash: String?

    init(sourceURL: URL, date: Date, relativePath: String,
         wasProcessed: Bool = false, sourceContentHash: String? = nil) {
        self.sourceURL = sourceURL
        self.date = date
        self.relativePath = relativePath
        self.wasProcessed = wasProcessed
        self.sourceContentHash = sourceContentHash
    }

    func extractTags() -> [String] {
        var tags: [String] = []

        let pathComponents = relativePath.split(separator: "/").map(String.init)
        if pathComponents.count > 1 {
            tags.append(contentsOf: pathComponents.dropLast())
        }

        let filename = sourceURL.deletingPathExtension().lastPathComponent
        if !filename.isEmpty {
            tags.append(filename)
        }

        return tags
    }
}

struct ImportResult: Sendable {
    let imported: [URL]
    let failed: [FileFailure]
    let importedInfo: [ImportedFileInfo]
    let skipped: [URL]
    let discarded: [URL]
    let deferred: [URL]
    let metadataError: String?

    init(imported: [URL] = [], failed: [FileFailure] = [],
         importedInfo: [ImportedFileInfo] = [], skipped: [URL] = [],
         discarded: [URL] = [], deferred: [URL] = [],
         metadataError: String? = nil) {
        self.imported = imported
        self.failed = failed
        self.importedInfo = importedInfo
        self.skipped = skipped
        self.discarded = discarded
        self.deferred = deferred
        self.metadataError = metadataError
    }
}

/// Post-encrypt snapshot shown by the import confirmation modal.
public struct ImportSummary: Sendable, Identifiable {
    /// Stable identifier for SwiftUI.
    public let id = UUID()
    /// Number of files successfully encrypted into staging.
    public let succeeded: Int
    /// Per-file failures during staging.
    public let failed: [FileFailure]
    /// True when this summary corresponds to resuming a previously-staged import.
    public let isResumed: Bool

    /// Create a summary with success count, per-file failures, and whether the import is being resumed.
    public init(succeeded: Int, failed: [FileFailure], isResumed: Bool = false) {
        self.succeeded = succeeded
        self.failed = failed
        self.isResumed = isResumed
    }

    /// Total of succeeded plus failed file counts.
    public var totalAttempted: Int { succeeded + failed.count }
}

/// User decision from the import confirmation modal.
public enum ImportDecision: Sendable {
    /// Commit all successfully-staged files into the data folder.
    case importStaged
    /// Discard staged files without committing.
    case discard
    /// Retry only the previously-failed files.
    case retryFailed
    /// Leave the staged manifest on disk for resumption on the next session.
    /// Resolved by the Cancel button, idle timeout, or session lock.
    case deferred
}

enum ImportPhase: Sendable, Equatable {
    case scanning
    case preparing
    case encrypting
}

struct ImportProgress: Sendable {
    let phase: ImportPhase
    let processedFiles: Int
    let totalFiles: Int
    let currentFile: String?

    init(phase: ImportPhase = .encrypting, processedFiles: Int = 0, totalFiles: Int = 0, currentFile: String? = nil) {
        self.phase = phase
        self.processedFiles = processedFiles
        self.totalFiles = totalFiles
        self.currentFile = currentFile
    }
}
