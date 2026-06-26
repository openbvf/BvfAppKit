import Foundation
import BvfAppKit

struct ImportManifest: Codable, Sendable {
    let version: Int
    let importID: String
    let destinationURL: URL
    let createdAt: Date
    var status: Status
    var entries: [Entry]

    init(importID: String, destinationURL: URL, entries: [Entry]) {
        self.version = 1
        self.importID = importID
        self.destinationURL = destinationURL
        self.createdAt = Date()
        self.status = .awaitingConfirm
        self.entries = entries
    }

    enum Status: String, Codable, Sendable {
        case awaitingConfirm
        case deferred
        case committing
        case done
    }

    struct Entry: Codable, Sendable {
        let sourceURL: URL
        let date: Date
        let suffix: String
        let relativePath: String
        let stagedName: String
        var destinationPath: URL?
    }
}

struct ImportFailureMarker: Codable, Sendable {
    let sourceURL: URL
    let errorDescription: String
}

/// Per-staged-file sidecar written by the encrypt task.
/// Captures encrypt-time outcomes (was the file transformed, hash of original)
/// that aren't known until the file processor runs.
struct ImportEntryOutcome: Codable, Sendable {
    let wasProcessed: Bool
    let sourceContentHash: String?
}

enum ImportManifestStore {
    static let stageRootName = ".importStage"
    static let manifestFilename = "manifest.json"
    static let failuresSubdir = "failures"

    static func stageRoot(under destination: URL) -> URL {
        destination.appendingPathComponent(stageRootName, isDirectory: true)
    }

    static func newImportDir(under destination: URL) -> (importID: String, url: URL) {
        let importID = UUID().uuidString
        let url = stageRoot(under: destination)
            .appendingPathComponent("import-\(importID)", isDirectory: true)
        return (importID, url)
    }

    /// Scan `.importStage/` for resumable imports. Side effect: discards any
    /// non-resumable or unreadable manifest dirs, and any non-newest resumable
    /// dir if multiple exist (the pre-flight gate makes that case theoretical).
    static func findExistingImport(under destination: URL) -> URL? {
        let root = stageRoot(under: destination)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return nil }

        var resumable: [(URL, ImportManifest)] = []
        for url in contents {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent(manifestFilename).path) else {
                discard(url)
                continue
            }
            guard let manifest = try? load(from: url) else {
                discard(url)
                continue
            }
            switch manifest.status {
            case .deferred, .committing:
                resumable.append((url, manifest))
            case .awaitingConfirm, .done:
                discard(url)
            }
        }

        resumable.sort { $0.1.createdAt > $1.1.createdAt }
        for (url, _) in resumable.dropFirst() { discard(url) }
        return resumable.first?.0
    }

    /// ISO8601 with fractional seconds. Foundation's `.iso8601` strategy uses second
    /// precision, which truncates `entry.date` and `createdAt` on round-trip — bad for
    /// destination-path minting after resume, and bad for stable `findExistingImport` sort.
    /// ISO8601DateFormatter is thread-safe (documented since macOS 10.12) but not Sendable.
    nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    @Sendable private static func encodeDate(_ date: Date, to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(dateFormatter.string(from: date))
    }

    @Sendable private static func decodeDate(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let date = dateFormatter.date(from: string) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid ISO8601 date: \(string)"
            )
        }
        return date
    }

    static func write(_ manifest: ImportManifest, in importDir: URL) throws {
        try FileManager.default.createDirectory(at: importDir, withIntermediateDirectories: true)
        let url = importDir.appendingPathComponent(manifestFilename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom(encodeDate)
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    static func load(from importDir: URL) throws -> ImportManifest {
        let url = importDir.appendingPathComponent(manifestFilename)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(decodeDate)
        return try decoder.decode(ImportManifest.self, from: data)
    }

    static func recordFailure(_ failure: ImportFailureMarker, in importDir: URL) throws {
        let dir = importDir.appendingPathComponent(failuresSubdir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        let data = try encoder.encode(failure)
        try data.write(to: url, options: .atomic)
    }

    static func loadFailures(from importDir: URL) -> [ImportFailureMarker] {
        let dir = importDir.appendingPathComponent(failuresSubdir)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        let decoder = JSONDecoder()
        return contents.compactMap { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(ImportFailureMarker.self, from: data)
        }
    }

    static func clearFailures(in importDir: URL) {
        let dir = importDir.appendingPathComponent(failuresSubdir)
        try? FileManager.default.removeItem(at: dir)
    }

    static func stagedFiles(in importDir: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: importDir, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return contents.filter { $0.pathExtension == "bvf" }
    }

    static func outcomeURL(for stagedName: String, in importDir: URL) -> URL {
        importDir.appendingPathComponent("\(stagedName).outcome.json")
    }

    static func writeOutcome(_ outcome: ImportEntryOutcome, for stagedName: String, in importDir: URL) throws {
        let url = outcomeURL(for: stagedName, in: importDir)
        let data = try JSONEncoder().encode(outcome)
        try data.write(to: url, options: .atomic)
    }

    static func loadOutcome(for stagedName: String, in importDir: URL) -> ImportEntryOutcome {
        let url = outcomeURL(for: stagedName, in: importDir)
        guard let data = try? Data(contentsOf: url),
              let outcome = try? JSONDecoder().decode(ImportEntryOutcome.self, from: data) else {
            return ImportEntryOutcome(wasProcessed: false, sourceContentHash: nil)
        }
        return outcome
    }

    static func discard(_ importDir: URL) {
        try? FileManager.default.removeItem(at: importDir)
        let parent = importDir.deletingLastPathComponent()
        if let remaining = try? FileManager.default.contentsOfDirectory(atPath: parent.path),
           remaining.isEmpty {
            try? FileManager.default.removeItem(at: parent)
        }
    }
}
