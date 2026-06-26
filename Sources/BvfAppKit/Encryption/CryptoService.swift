import Foundation
import BvfKit

/// Errors from cryptographic operations within BvfAppKit.
/// Wraps underlying BvfKit errors so consumers never need to import BvfKit directly.
public enum CryptoError: LocalizedError {
    /// The supplied key file is malformed or unreadable.
    case invalidKey(Error)
    /// Encryption stream failed mid-operation.
    case encryptionFailed(Error)
    /// Decryption stream failed mid-operation.
    case decryptionFailed(Error)
    /// The passphrase did not derive the expected key.
    case wrongPassphrase

    /// Human-readable description for `LocalizedError`.
    public var errorDescription: String? {
        switch self {
        case .invalidKey(let error):
            return "Invalid key: \(error.localizedDescription)"
        case .encryptionFailed(let error):
            return "Encryption failed: \(error.localizedDescription)"
        case .decryptionFailed(let error):
            return "Decryption failed: \(error.localizedDescription)"
        case .wrongPassphrase:
            return "Incorrect passphrase"
        }
    }
}

/// Service responsible for file encryption/decryption operations
/// Thin wrapper around BvfKit library - Encrypter/Decrypter handle all file format details
public struct CryptoService: Sendable {
    /// Size of the bvf-v1 file header in bytes. Files at or below this size contain no data.
    public static let headerSize = BvfConfig.headerSize

    /// Create a stateless crypto service.
    public init() {}

    private func makeEncrypter(publicKeyURL: URL) throws -> Encrypter {
        do {
            let publicKey = try readKeyFile(at: publicKeyURL)
            return try Encrypter(recipientPublicKey: publicKey)
        } catch {
            throw CryptoError.invalidKey(error)
        }
    }

    /// Encrypt plaintext data and write to file
    /// - Parameters:
    ///   - plaintext: Data to encrypt
    ///   - publicKeyURL: URL to the public key file
    ///   - outputPath: File URL where encrypted data will be written
    /// - Throws: CryptoError.invalidKey, CryptoError.encryptionFailed, or file I/O errors
    public func encryptDataToFile(plaintext: Data, publicKeyURL: URL, outputPath: URL) throws {
        let encrypter = try makeEncrypter(publicKeyURL: publicKeyURL)

        FileManager.default.createFile(atPath: outputPath.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputPath)
        defer { try? outputHandle.close() }

        do {
            try encrypter.encrypt(plaintext) { try outputHandle.write(contentsOf: $0) }
        } catch {
            throw CryptoError.encryptionFailed(error)
        }

    }

    /// Encrypt a file directly to another file
    /// - Parameters:
    ///   - inputPath: URL to plaintext file to encrypt
    ///   - publicKeyURL: URL to the public key file
    ///   - outputPath: File URL where encrypted data will be written
    /// - Throws: CryptoError.invalidKey, CryptoError.encryptionFailed, or file I/O errors
    public func encryptFileToFile(inputPath: URL, publicKeyURL: URL, outputPath: URL) throws {
        let encrypter = try makeEncrypter(publicKeyURL: publicKeyURL)

        let inputHandle = try FileHandle(forReadingFrom: inputPath)
        defer { try? inputHandle.close() }

        FileManager.default.createFile(atPath: outputPath.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputPath)
        defer { try? outputHandle.close() }

        do {
            try encrypter.encrypt(
                from: { size in try inputHandle.read(upToCount: size) },
                to: { try outputHandle.write(contentsOf: $0) }
            )
        } catch {
            throw CryptoError.encryptionFailed(error)
        }
    }

    /// Validate a public key file at the given URL
    /// - Throws: CryptoError.invalidKey
    public func validatePublicKeyFile(at url: URL) throws {
        do {
            let keyString = try readKeyFile(at: url)
            _ = try PublicKeyFormat.decode(keyString)
        } catch {
            throw CryptoError.invalidKey(error)
        }
    }

    /// Validate an encrypted private key file at the given URL
    /// - Throws: CryptoError.invalidKey
    public func validatePrivateKeyFile(at url: URL) throws {
        do {
            let data = try Data(contentsOf: url)
            _ = try PrivateKeyFormat.validate(data)
        } catch {
            throw CryptoError.invalidKey(error)
        }
    }

    /// Start a streaming encryption session, returning the header, chunk size, and an encrypt closure
    /// - Throws: CryptoError.invalidKey or CryptoError.encryptionFailed
    internal func startStreamEncryption(publicKeyURL: URL) throws -> (header: Data, chunkSize: Int, encryptChunk: (Data, Bool) throws -> Data) {
        let encrypter = try makeEncrypter(publicKeyURL: publicKeyURL)

        do {
            let (header, state) = try encrypter.start()
            return (header, BvfConfig.plaintextChunkSize, { try state.encryptChunk($0, isLast: $1) })
        } catch {
            throw CryptoError.encryptionFailed(error)
        }
    }
}
