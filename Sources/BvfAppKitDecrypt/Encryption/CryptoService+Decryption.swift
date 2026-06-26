import Foundation
import BvfKit

extension CryptoService {
    /// Create a decryption session for lazy on-demand decryption
    /// - Throws: CryptoError.wrongPassphrase, CryptoError.invalidKey
    public func createSession(keyPath: URL, passphrase: String) throws -> DecryptionSession {
        do {
            let encryptedPrivateKey = try Data(contentsOf: keyPath)
            let decrypter = try Decrypter(encryptedPrivateKey: encryptedPrivateKey, passphrase: passphrase)
            return DecryptionSession(decrypter: decrypter)
        } catch let error as BvfError where error == .wrongPassphrase {
            throw CryptoError.wrongPassphrase
        } catch {
            throw CryptoError.invalidKey(error)
        }
    }
}
