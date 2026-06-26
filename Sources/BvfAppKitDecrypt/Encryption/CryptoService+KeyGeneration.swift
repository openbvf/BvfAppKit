import Foundation
import BvfKit

extension CryptoService {

    struct GeneratedKeypair: Sendable {
        let encryptedPrivateKeyData: Data
        let publicKeyString: String
    }

    /// Generate a new keypair and encrypt the private key with the passphrase
    /// - Parameter passphrase: Passphrase for encrypting private key
    /// - Returns: Generated keypair data ready to be written to files
    /// - Throws: CryptoError.encryptionFailed if key generation fails
    func generateKeypair(passphrase: String) async throws -> GeneratedKeypair {
        // Move CPU-intensive Argon2id work off main thread to prevent UI freezing
        return try await Task.detached {
            do {
                let keypair = try Keypair.generate()
                let encryptedPrivateKeyData = try keypair.exportEncryptedPrivateKey(passphrase: passphrase)

                return GeneratedKeypair(
                    encryptedPrivateKeyData: encryptedPrivateKeyData,
                    publicKeyString: keypair.publicKey
                )
            } catch {
                throw CryptoError.encryptionFailed(error)
            }
        }.value
    }

    /// Write keypair files to specified URLs
    /// Private key is created with 0600 permissions from the start to avoid any window of exposure.
    /// On failure, any partial private key file is deleted before rethrowing.
    func saveKeypairToFiles(
        keypair: GeneratedKeypair,
        privateKeyURL: URL,
        publicKeyURL: URL
    ) throws {
        do {
            guard FileManager.default.createFile(
                atPath: privateKeyURL.path,
                contents: keypair.encryptedPrivateKeyData,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CryptoError.encryptionFailed(
                    NSError(domain: "KeyGeneration", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to create private key file"])
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: privateKeyURL)
            throw error
        }

        try keypair.publicKeyString.write(to: publicKeyURL, atomically: true, encoding: .utf8)
    }
}
