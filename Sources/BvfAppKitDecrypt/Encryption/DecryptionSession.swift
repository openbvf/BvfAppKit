import Foundation
import BvfKit

/// Plaintext result of a single-file decryption.
public struct DecryptionResult: Sendable {
    /// Decrypted bytes.
    public let data: Data
    /// True if the encrypted input ended mid-stream.
    public let wasTruncated: Bool
}

/// Holds an unlocked private key in BvfKit's locked memory for the lifetime of the session.
public final class DecryptionSession: Sendable {
    private let decrypter: Decrypter

    init(decrypter: Decrypter) {
        self.decrypter = decrypter
    }

    /// Public key paired with the session's unlocked private key.
    public var publicKey: String {
        decrypter.publicKey
    }

    private func decryptFile(_ url: URL) throws -> DecryptionResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        do {
            let (data, truncated) = try decrypter.decrypt { count in
                try Task.checkCancellation()
                return try handle.read(upToCount: count)
            }
            return DecryptionResult(data: data, wasTruncated: truncated)
        } catch {
            throw CryptoError.decryptionFailed(error)
        }
    }

    /// Decrypt the full contents of `url` to memory.
    public func decrypt(contentsOf url: URL) async throws -> DecryptionResult {
        try await ConcurrencyLimiter.shared.run {
            try Task.checkCancellation()
            return try self.decryptFile(url)
        }
    }

    /// Decrypt `url` and apply `transform` to the plaintext within the concurrency-limited block.
    public func decryptAndTransform<T: Sendable>(
        contentsOf url: URL,
        transform: @Sendable (Data) throws -> T
    ) async throws -> T {
        try await ConcurrencyLimiter.shared.run {
            try Task.checkCancellation()
            let result = try self.decryptFile(url)
            return try transform(result.data)
        }
    }

    /// Stream-decrypt `url`, invoking `write` with each plaintext chunk. Chunks are
    /// zeroed in BvfKit after `write` returns. Throws on truncated input.
    public func decrypt(
        contentsOf url: URL,
        into write: @Sendable (Data) throws -> Void
    ) async throws {
        try await ConcurrencyLimiter.shared.run {
            try Task.checkCancellation()
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            do {
                try self.decrypter.decrypt(
                    from: { count in
                        try Task.checkCancellation()
                        return try handle.read(upToCount: count)
                    },
                    to: write
                )
            } catch {
                throw CryptoError.decryptionFailed(error)
            }
        }
    }
}
