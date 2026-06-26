import Foundation
import Darwin
import CryptoKit

/// Service responsible for importing files/directories into encrypted storage.
///
/// Lifecycle:
/// 1. **Pre-flight gate** — if a previous interrupted import exists for `destination`,
///    resume it via the same modal. The new `urls`/options are ignored for that call.
/// 2. **Enumerate + iCloud trigger** — walk source URLs, fire-and-forget
///    `startDownloadingUbiquitousItem` for each.
/// 3. **Allocate** — plan one `ImportManifest.Entry` per file (sourceURL, date, suffix,
///    relativePath, stagedName).
/// 4. **Stage + manifest write** — create `{destination}/.importStage/import-{uuid}/`,
///    write `manifest.json`.
/// 5. **Encrypt** — parallel; each task writes either a staged `.bvf` or a per-file
///    failure marker. No shared mutable state during encrypt.
/// 6. **Modal loop** — `confirmAction(summary)` returns Import / Discard / RetryFailed.
///    Retry re-encrypts only entries without a staged file.
/// 7. **Finalize** — on Import: defer-compute `BvfStore.allocate` per entry, move from
///    staging to destination, call `metadataWriter`, then nuke staging.
final class DirectoryImportService: Sendable {
    private let cryptoService: CryptoService

    init(cryptoService: CryptoService = CryptoService()) {
        self.cryptoService = cryptoService
    }

    func importFiles(
        _ urls: [URL],
        to destination: URL,
        publicKeyURL: URL,
        rootURL: URL? = nil,
        dateExtractor: (@Sendable (URL) -> Date)? = nil,
        fileFilter: (@Sendable (URL) -> Bool)? = nil,
        outputSuffix: (@Sendable (URL) -> String)? = nil,
        fileProcessor: (@Sendable (URL) throws -> Data?)? = nil,
        confirmAction: @Sendable (ImportSummary) async -> ImportDecision = { _ in .importStaged },
        metadataWriter: (@Sendable ([ImportedFileInfo]) async throws -> Void)? = nil,
        onProgress: @Sendable (ImportProgress) -> Void
    ) async throws -> ImportResult {
        if let existingDir = ImportManifestStore.findExistingImport(under: destination) {
            return try await resumeImport(
                importDir: existingDir,
                publicKeyURL: publicKeyURL,
                fileProcessor: fileProcessor,
                confirmAction: confirmAction,
                metadataWriter: metadataWriter,
                onProgress: onProgress
            )
        }
        return try await runImport(
            urls: urls, to: destination, publicKeyURL: publicKeyURL,
            rootURL: rootURL, dateExtractor: dateExtractor,
            fileFilter: fileFilter, outputSuffix: outputSuffix,
            fileProcessor: fileProcessor,
            confirmAction: confirmAction, metadataWriter: metadataWriter,
            onProgress: onProgress
        )
    }

    /// Cheap probe — true if a pending or interrupted import is staged at
    /// `destination`. Used by callers (e.g. browse VM after unlock) to decide
    /// whether to invoke `importFiles` solely to resume an existing import.
    static func hasPendingImport(at destination: URL) -> Bool {
        ImportManifestStore.findExistingImport(under: destination) != nil
    }

    private func runImport(
        urls: [URL], to destination: URL, publicKeyURL: URL,
        rootURL: URL?,
        dateExtractor: (@Sendable (URL) -> Date)?,
        fileFilter: (@Sendable (URL) -> Bool)?,
        outputSuffix: (@Sendable (URL) -> String)?,
        fileProcessor: (@Sendable (URL) throws -> Data?)?,
        confirmAction: @Sendable (ImportSummary) async -> ImportDecision,
        metadataWriter: (@Sendable ([ImportedFileInfo]) async throws -> Void)?,
        onProgress: @Sendable (ImportProgress) -> Void
    ) async throws -> ImportResult {
        let (allFiles, skipped) = enumerateFiles(
            from: urls, fileFilter: fileFilter, onProgress: onProgress
        )
        triggerICloudDownloads(for: allFiles)
        let (entries, allocFailures) = allocateEntries(
            files: allFiles, rootURL: rootURL,
            dateExtractor: dateExtractor, outputSuffix: outputSuffix,
            onProgress: onProgress
        )
        let (importID, importDir) = ImportManifestStore.newImportDir(under: destination)
        try FileManager.default.createDirectory(at: importDir, withIntermediateDirectories: true)
        let manifest = ImportManifest(
            importID: importID, destinationURL: destination, entries: entries
        )
        try ImportManifestStore.write(manifest, in: importDir)
        await encryptEntries(
            entries: entries, in: importDir,
            publicKeyURL: publicKeyURL, fileProcessor: fileProcessor,
            onProgress: onProgress
        )
        return try await modalAndFinalize(
            importDir: importDir, manifest: manifest,
            skipped: skipped, allocFailures: allocFailures,
            isResumed: false,
            publicKeyURL: publicKeyURL, fileProcessor: fileProcessor,
            confirmAction: confirmAction, metadataWriter: metadataWriter,
            onProgress: onProgress
        )
    }

    private func resumeImport(
        importDir: URL, publicKeyURL: URL,
        fileProcessor: (@Sendable (URL) throws -> Data?)?,
        confirmAction: @Sendable (ImportSummary) async -> ImportDecision,
        metadataWriter: (@Sendable ([ImportedFileInfo]) async throws -> Void)?,
        onProgress: @Sendable (ImportProgress) -> Void
    ) async throws -> ImportResult {
        let manifest = try ImportManifestStore.load(from: importDir)
        switch manifest.status {
        case .committing:
            // Crash mid-finalize. Re-run silently — destinations are already
            // persisted on entries so already-moved files are re-included in
            // the imported list and the metadata writer sees the full set.
            return try await finalize(
                importDir: importDir, manifest: manifest,
                skipped: [], allocFailures: [],
                metadataWriter: metadataWriter
            )
        case .deferred:
            return try await modalAndFinalize(
                importDir: importDir, manifest: manifest,
                skipped: [], allocFailures: [],
                isResumed: true,
                publicKeyURL: publicKeyURL, fileProcessor: fileProcessor,
                confirmAction: confirmAction, metadataWriter: metadataWriter,
                onProgress: onProgress
            )
        case .awaitingConfirm, .done:
            // findExistingImport should have filtered these out — defensive.
            ImportManifestStore.discard(importDir)
            return ImportResult()
        }
    }

    private func modalAndFinalize(
        importDir: URL, manifest: ImportManifest,
        skipped: [URL], allocFailures: [FileFailure],
        isResumed: Bool,
        publicKeyURL: URL,
        fileProcessor: (@Sendable (URL) throws -> Data?)?,
        confirmAction: @Sendable (ImportSummary) async -> ImportDecision,
        metadataWriter: (@Sendable ([ImportedFileInfo]) async throws -> Void)?,
        onProgress: @Sendable (ImportProgress) -> Void
    ) async throws -> ImportResult {
        while true {
            let summary = buildSummary(
                manifest: manifest, importDir: importDir,
                allocFailures: allocFailures, isResumed: isResumed
            )
            let decision = await confirmAction(summary)
            switch decision {
            case .importStaged:
                return try await finalize(
                    importDir: importDir, manifest: manifest,
                    skipped: skipped, allocFailures: allocFailures,
                    metadataWriter: metadataWriter
                )
            case .discard:
                let allURLs = manifest.entries.map(\.sourceURL)
                ImportManifestStore.discard(importDir)
                return ImportResult(
                    failed: allocFailures, skipped: skipped, discarded: allURLs
                )
            case .retryFailed:
                await retryFailed(
                    importDir: importDir, manifest: manifest,
                    publicKeyURL: publicKeyURL, fileProcessor: fileProcessor,
                    onProgress: onProgress
                )
                // Loop back to the modal with refreshed summary.
            case .deferred:
                // Persist status so findExistingImport's scan recognizes this
                // as resumable rather than abandoned-mid-encrypt.
                var deferredManifest = manifest
                deferredManifest.status = .deferred
                try? ImportManifestStore.write(deferredManifest, in: importDir)
                return ImportResult(
                    failed: allocFailures, skipped: skipped,
                    deferred: manifest.entries.map(\.sourceURL)
                )
            }
        }
    }

    private func buildSummary(
        manifest: ImportManifest, importDir: URL,
        allocFailures: [FileFailure], isResumed: Bool
    ) -> ImportSummary {
        let stagedNames = Set(
            ImportManifestStore.stagedFiles(in: importDir).map(\.lastPathComponent)
        )
        let succeeded = manifest.entries.filter { stagedNames.contains($0.stagedName) }.count
        let encryptFailures = ImportManifestStore.loadFailures(from: importDir).map {
            FileFailure(url: $0.sourceURL, errorDescription: $0.errorDescription)
        }
        return ImportSummary(
            succeeded: succeeded,
            failed: allocFailures + encryptFailures,
            isResumed: isResumed
        )
    }

    private func retryFailed(
        importDir: URL, manifest: ImportManifest,
        publicKeyURL: URL,
        fileProcessor: (@Sendable (URL) throws -> Data?)?,
        onProgress: @Sendable (ImportProgress) -> Void
    ) async {
        let stagedNames = Set(
            ImportManifestStore.stagedFiles(in: importDir).map(\.lastPathComponent)
        )
        let needsRetry = manifest.entries.filter { !stagedNames.contains($0.stagedName) }
        ImportManifestStore.clearFailures(in: importDir)
        await encryptEntries(
            entries: needsRetry, in: importDir,
            publicKeyURL: publicKeyURL, fileProcessor: fileProcessor,
            onProgress: onProgress
        )
    }

    private func finalize(
        importDir: URL, manifest: ImportManifest,
        skipped: [URL], allocFailures: [FileFailure],
        metadataWriter: (@Sendable ([ImportedFileInfo]) async throws -> Void)?
    ) async throws -> ImportResult {
        // Pre-compute destination paths for any entry with a staged file that
        // doesn't already have one assigned. Reserves paths across entries to
        // avoid mutual collisions among same-timestamp entries. Persists the
        // updated manifest with .committing status before any moves so a
        // crash mid-move can still locate already-moved files on resume.
        var committingManifest = manifest
        committingManifest.status = .committing
        var reserved = Set<String>(
            committingManifest.entries.compactMap { $0.destinationPath?.path }
        )
        for index in committingManifest.entries.indices {
            guard committingManifest.entries[index].destinationPath == nil else { continue }
            let entry = committingManifest.entries[index]
            let stagedPath = importDir.appendingPathComponent(entry.stagedName)
            guard FileManager.default.fileExists(atPath: stagedPath.path) else { continue }
            let (destPath, _) = BvfStore.allocate(
                date: entry.date, suffix: entry.suffix,
                in: manifest.destinationURL,
                reserved: reserved
            )
            reserved.insert(destPath.path)
            committingManifest.entries[index].destinationPath = destPath
        }
        try ImportManifestStore.write(committingManifest, in: importDir)

        var imported: [ImportedFileInfo] = []
        var moveFailures: [FileFailure] = []
        let didStartDestAccess = manifest.destinationURL.startAccessingSecurityScopedResource()
        defer { if didStartDestAccess { manifest.destinationURL.stopAccessingSecurityScopedResource() } }
        for entry in committingManifest.entries {
            guard let destPath = entry.destinationPath else { continue }
            let stagedPath = importDir.appendingPathComponent(entry.stagedName)
            let stagedExists = FileManager.default.fileExists(atPath: stagedPath.path)
            let destExists = FileManager.default.fileExists(atPath: destPath.path)

            if stagedExists {
                do {
                    try BvfStore.move(staged: stagedPath, to: destPath)
                } catch {
                    moveFailures.append(FileFailure(
                        url: entry.sourceURL,
                        errorDescription: "Move failed: \(error.localizedDescription)"
                    ))
                    continue
                }
            } else if !destExists {
                // Neither staged nor at destination — something else removed it.
                moveFailures.append(FileFailure(
                    url: entry.sourceURL,
                    errorDescription: "File not found at destination"
                ))
                continue
            }
            // Either freshly moved or moved on a prior run — include in imported.
            let outcome = ImportManifestStore.loadOutcome(
                for: entry.stagedName, in: importDir
            )
            imported.append(ImportedFileInfo(
                sourceURL: entry.sourceURL,
                date: entry.date,
                relativePath: entry.relativePath,
                wasProcessed: outcome.wasProcessed,
                sourceContentHash: outcome.sourceContentHash
            ))
        }

        let encryptFailures = ImportManifestStore.loadFailures(from: importDir).map {
            FileFailure(url: $0.sourceURL, errorDescription: $0.errorDescription)
        }

        // Cleanup staging regardless of metadataWriter outcome — files are at
        // destination either way, and we don't want a permanently-failing
        // metadata write to leave a stale manifest blocking future imports.
        defer { ImportManifestStore.discard(importDir) }

        var metadataError: String?
        if let metadataWriter, !imported.isEmpty {
            do {
                try await metadataWriter(imported)
            } catch {
                metadataError = error.localizedDescription
            }
        }

        return ImportResult(
            imported: imported.map(\.sourceURL),
            failed: allocFailures + encryptFailures + moveFailures,
            importedInfo: imported,
            skipped: skipped,
            metadataError: metadataError
        )
    }

    private func triggerICloudDownloads(for urls: [URL]) {
        for url in urls {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
    }

    private func enumerateFiles(
        from urls: [URL],
        fileFilter: ((URL) -> Bool)?,
        onProgress: (ImportProgress) -> Void
    ) -> (allFiles: [URL], skipped: [URL]) {
        var allFiles: [URL] = []
        var skipped: [URL] = []

        func record(_ url: URL) {
            if let filter = fileFilter, !filter(url) {
                skipped.append(url)
                return
            }
            allFiles.append(url)
            if allFiles.count.isMultiple(of: BvfAppKitConfig.importProgressInterval) {
                onProgress(ImportProgress(phase: .scanning, processedFiles: allFiles.count, totalFiles: 0))
            }
        }

        for url in urls {
            guard let isDirectory = isDirectoryAt(url) else { continue }
            if isDirectory {
                guard let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                while let fileURL = enumerator.nextObject() as? URL {
                    let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
                    guard values?.isRegularFile == true else { continue }
                    record(fileURL)
                }
            } else {
                record(url)
            }
        }
        return (allFiles, skipped)
    }

    private func isDirectoryAt(_ url: URL) -> Bool? {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        return values?.isDirectory
    }

    private func allocateEntries(
        files: [URL],
        rootURL: URL?,
        dateExtractor: (@Sendable (URL) -> Date)?,
        outputSuffix: (@Sendable (URL) -> String)?,
        onProgress: (ImportProgress) -> Void
    ) -> (entries: [ImportManifest.Entry], failures: [FileFailure]) {
        var entries: [ImportManifest.Entry] = []
        var failures: [FileFailure] = []

        for fileURL in files {
            do {
                let date = try dateExtractor.map { $0(fileURL) } ?? extractCreationDate(from: fileURL)
                let suffix = outputSuffix?(fileURL) ?? defaultSuffix(for: fileURL)
                let relativePath = computeRelativePath(from: rootURL, to: fileURL)
                let stagedName = "\(UUID().uuidString).bvf"

                entries.append(ImportManifest.Entry(
                    sourceURL: fileURL, date: date, suffix: suffix,
                    relativePath: relativePath, stagedName: stagedName
                ))
                if entries.count.isMultiple(of: BvfAppKitConfig.importProgressInterval) {
                    onProgress(ImportProgress(
                        phase: .preparing,
                        processedFiles: entries.count,
                        totalFiles: files.count
                    ))
                }
            } catch {
                failures.append(FileFailure(url: fileURL, errorDescription: error.localizedDescription))
            }
        }
        return (entries, failures)
    }

    private func encryptEntries(
        entries: [ImportManifest.Entry],
        in importDir: URL,
        publicKeyURL: URL,
        fileProcessor: (@Sendable (URL) throws -> Data?)?,
        onProgress: @Sendable (ImportProgress) -> Void
    ) async {
        let limiter = ConcurrencyLimiter(limit: ProcessInfo.processInfo.activeProcessorCount)
        var completed = 0
        let total = entries.count
        let importDirCapture = importDir

        await withTaskGroup(of: Void.self) { group in
            for entry in entries {
                group.addTask {
                    do {
                        try await limiter.runSync {
                            try self.encryptOne(
                                entry, in: importDirCapture,
                                publicKeyURL: publicKeyURL,
                                fileProcessor: fileProcessor
                            )
                        }
                    } catch {
                        try? ImportManifestStore.recordFailure(
                            ImportFailureMarker(
                                sourceURL: entry.sourceURL,
                                errorDescription: error.localizedDescription
                            ),
                            in: importDirCapture
                        )
                    }
                }
            }
            for await _ in group {
                completed += 1
                onProgress(ImportProgress(
                    processedFiles: completed,
                    totalFiles: total,
                    currentFile: nil
                ))
            }
        }
    }

    private func encryptOne(
        _ entry: ImportManifest.Entry,
        in importDir: URL,
        publicKeyURL: URL,
        fileProcessor: (@Sendable (URL) throws -> Data?)?
    ) throws {
        let stagedPath = importDir.appendingPathComponent(entry.stagedName)
        let scratchDir = importDir.appendingPathComponent(".tmp", isDirectory: true)

        if let processor = fileProcessor, let data = try processor(entry.sourceURL) {
            let hash = try streamingSHA256Hex(of: entry.sourceURL)
            let tempFile = try StagingManager.stage(
                date: entry.date, suffix: entry.suffix, stagingURL: scratchDir
            ) {
                try cryptoService.encryptDataToFile(
                    plaintext: data, publicKeyURL: publicKeyURL, outputPath: $0
                )
            }
            try BvfStore.move(staged: tempFile, to: stagedPath)
            try ImportManifestStore.writeOutcome(
                ImportEntryOutcome(wasProcessed: true, sourceContentHash: hash),
                for: entry.stagedName, in: importDir
            )
        } else {
            let tempFile = try StagingManager.stage(
                date: entry.date, suffix: entry.suffix, stagingURL: scratchDir
            ) {
                try cryptoService.encryptFileToFile(
                    inputPath: entry.sourceURL, publicKeyURL: publicKeyURL, outputPath: $0
                )
            }
            try BvfStore.move(staged: tempFile, to: stagedPath)
            try ImportManifestStore.writeOutcome(
                ImportEntryOutcome(wasProcessed: false, sourceContentHash: nil),
                for: entry.stagedName, in: importDir
            )
        }
    }

    private func streamingSHA256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func defaultSuffix(for url: URL) -> String {
        url.pathExtension.lowercased()
    }

    private func extractCreationDate(from url: URL) throws -> Date {
        let values = try url.resourceValues(forKeys: [.creationDateKey])
        guard let creationDate = values.creationDate else {
            throw DirectoryImportError.noCreationDate(url)
        }
        return creationDate
    }

    private func computeRelativePath(from rootURL: URL?, to targetURL: URL) -> String {
        guard let rootURL = rootURL else {
            return targetURL.lastPathComponent
        }
        let rootComps = canonicalComponents(rootURL)
        let targetComps = canonicalComponents(targetURL)
        guard targetComps.starts(with: rootComps), targetComps.count > rootComps.count else {
            return targetURL.lastPathComponent
        }
        return targetComps.dropFirst(rootComps.count).joined(separator: "/")
    }

    // realpath resolves macOS's /var → /private/var symlink that URL methods leave alone.
    private func canonicalComponents(_ url: URL) -> [String] {
        guard let resolved = realpath(url.path, nil) else {
            return url.pathComponents
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved)).pathComponents
    }
}

enum DirectoryImportError: LocalizedError {
    case noCreationDate(URL)

    var errorDescription: String? {
        switch self {
        case .noCreationDate(let url):
            return "Could not determine creation date for file: \(url.lastPathComponent)"
        }
    }
}
