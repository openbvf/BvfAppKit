import Foundation

enum BrowseImportExportOps {
    /// Run the import lifecycle: encrypt to staging, present confirmation via
    /// `confirmAction`, on Import call `metadataWriter` and finalize.
    /// Returns the final outcome as a ResponseMessage.
    @MainActor
    static func importFiles(
        _ urls: [URL],
        rootURL: URL?,
        folderURL: URL,
        publicKeyURL: URL,
        fileFilter: @escaping @Sendable (URL) -> Bool,
        outputSuffix: (@Sendable (URL) -> String)? = nil,
        fileProcessor: (@Sendable (URL) throws -> Data?)? = nil,
        confirmAction: @escaping @Sendable (ImportSummary) async -> ImportDecision,
        metadataWriter: @escaping @Sendable ([ImportedFileInfo]) async throws -> Void,
        onProgress: @escaping @MainActor (ResponseMessage) -> Void
    ) async -> ResponseMessage {
        let importService = DirectoryImportService()

        do {
            let result = try await importService.importFiles(
                urls,
                to: folderURL,
                publicKeyURL: publicKeyURL,
                rootURL: rootURL,
                dateExtractor: { url in
                    if let pathDate = url.bvfDate() {
                        return pathDate
                    }
                    let resourceValues = try? url.resourceValues(forKeys: [.creationDateKey])
                    return resourceValues?.creationDate ?? Date()
                },
                fileFilter: fileFilter,
                outputSuffix: outputSuffix,
                fileProcessor: fileProcessor,
                confirmAction: confirmAction,
                metadataWriter: metadataWriter,
                onProgress: { progress in
                    Task { @MainActor in
                        onProgress(progressMessage(for: progress))
                    }
                }
            )
            return outcomeMessage(for: result)
        } catch {
            return ResponseMessage("Import failed: \(error.localizedDescription)", type: .error)
        }
    }

    private static func progressMessage(for progress: ImportProgress) -> ResponseMessage {
        switch progress.phase {
        case .scanning:
            return ResponseMessage(
                "Scanning… (\(progress.processedFiles) files found)",
                type: .info
            )
        case .preparing:
            return ResponseMessage(
                "Preparing \(progress.processedFiles)/\(progress.totalFiles)",
                type: .info
            )
        case .encrypting:
            if let currentFile = progress.currentFile {
                return ResponseMessage(
                    "Encrypting \(progress.processedFiles)/\(progress.totalFiles): \(currentFile)",
                    type: .info
                )
            }
            return ResponseMessage(
                "Encrypting \(progress.processedFiles)/\(progress.totalFiles)",
                type: .info
            )
        }
    }

    private static func outcomeMessage(for result: ImportResult) -> ResponseMessage {
        let imported = result.imported.count
        let skipped = result.skipped.count
        let failed = result.failed.count
        let discarded = result.discarded.count
        let deferred = result.deferred.count

        if deferred > 0 && imported == 0 {
            return ResponseMessage(
                "Import paused — \(deferred) \(deferred == 1 ? "file" : "files") will resume on next session",
                type: .info
            )
        }

        if discarded > 0 && imported == 0 {
            return ResponseMessage(
                "Discarded \(discarded) \(discarded == 1 ? "file" : "files")",
                type: .info
            )
        }

        let fullReport = ResponseMessage.buildImportReportDetails(
            imported: result.imported,
            skipped: result.skipped,
            failed: result.failed
        )
        let display = "\(failed) failed, \(skipped) skipped, \(imported) imported"
            + (result.metadataError.map { " (metadata not saved: \($0))" } ?? "")
        let messageType: MessageType = (failed > 0 || result.metadataError != nil) ? .error : .info
        return ResponseMessage(display, type: messageType, detail: fullReport)
    }

    /// Run ExportService, return result message.
    static func exportFiles(
        urls: [URL],
        to destination: URL,
        session: DecryptionSession
    ) async -> ResponseMessage {
        let result = await ExportService.export(
            files: urls,
            to: destination,
            session: session
        )

        if result.failed.isEmpty {
            return ResponseMessage("Exported \(result.exported.count) files", type: .success)
        } else {
            let header = "Exported \(result.exported.count), \(result.failed.count) failed"
            let fullMessage = ResponseMessage.buildErrorDetails(header: header, failures: result.failed)
            let displayMessage = "Exported \(result.exported.count) files, \(result.failed.count) failed"
            return ResponseMessage(displayMessage, type: .error, detail: fullMessage)
        }
    }
}
