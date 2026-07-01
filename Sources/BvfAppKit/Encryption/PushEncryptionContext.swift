import Foundation
import Darwin

/// Context for push-based encryption — caller writes data incrementally, encryption flushes at chunkSize boundaries.
/// Handles staging, encryption setup, and final commit to a collision-free destination path.
///
/// Buffer hygiene, not full plaintext protection in memory: `finish()` and `deinit` zero the buffer's
/// unflushed tail via `memset_s`. Bulk residency is dominated by AVFoundation encoder pools, any temp file
/// written by AVAssetWriter / AVAudioRecorder, and `Data`'s heap allocator semantics — outside this object's reach.
/// Audited 2026-06-29 (eslogger): no AVAudioRecorder/AVAssetWriter disk scratch in current path; memory-residency concerns above unverified.
public final class PushEncryptionContext {
    private let outputHandle: FileHandle
    private let encryptChunk: (Data, Bool) throws -> Data
    private var buffer = Data()
    private let chunkSize: Int
    private var committed = false

    /// Path of the staged output file. Becomes the moved-to final destination after `finish()`.
    public let outputURL: URL
    private let destinationFolderURL: URL
    private let date: Date
    private let suffix: String
    private let stagingURL: URL

    /// Create a push encryption context, writing to staging until finish() commits to the destination.
    /// `stagingURL` defaults to the shared staging directory; tests override to isolate fixtures.
    public init(
        publicKeyURL: URL,
        to destinationFolderURL: URL,
        date: Date = Date(),
        suffix: String,
        stagingURL: URL = StagingManager.directoryURL
    ) throws {
        self.destinationFolderURL = destinationFolderURL
        self.date = date
        self.suffix = suffix
        self.stagingURL = stagingURL

        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        let outputURL = StagingManager.stagingPath(date: date, suffix: suffix, in: stagingURL)
        self.outputURL = outputURL

        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let cryptoService = CryptoService()
        let (header, chunkSize, encryptChunk) = try cryptoService.startStreamEncryption(publicKeyURL: publicKeyURL)
        self.chunkSize = chunkSize
        self.encryptChunk = encryptChunk

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        try outputHandle.write(contentsOf: header)
        self.outputHandle = outputHandle
    }

    /// Append `data` to the internal buffer; flushes encrypted chunks at `chunkSize` boundaries.
    public func write(_ data: Data) throws {
        buffer.append(data)

        while buffer.count >= chunkSize {
            let chunk = buffer.prefix(chunkSize)
            buffer = buffer.dropFirst(chunkSize)

            let encrypted = try encryptChunk(Data(chunk), false)
            try outputHandle.write(contentsOf: encrypted)
        }
    }

    /// Flush the buffer as the final chunk, then move the staged file to a collision-free path in the destination folder. Returns the final URL.
    @discardableResult
    public func finish() throws -> URL {
        try closeStream()

        let didStartAccess = destinationFolderURL.startAccessingSecurityScopedResource()
        defer { if didStartAccess { destinationFolderURL.stopAccessingSecurityScopedResource() } }

        let (finalPath, _) = try BvfStore.commit(staged: outputURL, date: date, suffix: suffix, in: destinationFolderURL)
        StagingManager.cleanupEmptyDirectories(above: outputURL, root: stagingURL)
        committed = true
        return finalPath
    }

    /// Flush remaining buffer with isLast=true, zero the buffer, and close file handle
    private func closeStream() throws {
        defer { try? outputHandle.close() }
        defer { Self.zero(&buffer) }
        let encrypted = try encryptChunk(buffer, true)
        try outputHandle.write(contentsOf: encrypted)
    }

    deinit {
        Self.zero(&buffer)
        try? outputHandle.close()
        if !committed {
            try? FileManager.default.removeItem(at: outputURL)
            StagingManager.cleanupEmptyDirectories(above: outputURL, root: stagingURL)
        }
    }

    private static func zero(_ data: inout Data) {
        data.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress, ptr.count > 0 else { return }
            _ = memset_s(base, ptr.count, 0, ptr.count)
        }
    }
}
