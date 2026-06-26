import Foundation

struct ExportService {
    struct ExportResult {
        let exported: [URL]
        let failed: [FileFailure]
    }

    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func export(
        files: [URL],
        to destination: URL,
        session: DecryptionSession
    ) async -> ExportResult {
        var exported: [URL] = []
        var failed: [FileFailure] = []

        for fileURL in files {
            do {
                let filename = try exportFilename(for: fileURL)
                let destinationURL = destination.appendingPathComponent(filename)
                let tempURL = destination.appendingPathComponent(".\(UUID().uuidString).tmp")

                try await streamDecrypt(from: fileURL, to: tempURL, session: session)

                do {
                    _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: tempURL)
                } catch {
                    try? FileManager.default.removeItem(at: tempURL)
                    throw error
                }

                if let date = fileURL.bvfDate() {
                    try? FileManager.default.setAttributes([
                        .creationDate: date,
                        .modificationDate: date
                    ], ofItemAtPath: destinationURL.path)
                }

                exported.append(destinationURL)
            } catch {
                failed.append(FileFailure(url: fileURL, errorDescription: error.localizedDescription))
            }
        }

        return ExportResult(exported: exported, failed: failed)
    }

    private static func streamDecrypt(
        from sourceURL: URL,
        to tempURL: URL,
        session: DecryptionSession
    ) async throws {
        try Data().write(to: tempURL)
        let handle = try FileHandle(forWritingTo: tempURL)
        do {
            try await session.decrypt(contentsOf: sourceURL) { chunk in
                try handle.write(contentsOf: chunk)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    private static func exportFilename(for url: URL) throws -> String {
        guard let date = url.bvfDate() else {
            throw BvfStoreError.malformedPath(url)
        }
        let ext = try BvfStore.deriveSuffix(from: url)
        return "\(filenameFormatter.string(from: date)).\(ext)"
    }
}
