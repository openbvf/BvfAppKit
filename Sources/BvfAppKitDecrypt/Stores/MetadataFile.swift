import Foundation

/// Reads and writes the per-folder encrypted `metadata.bvf` (tags and source provenance).
public enum MetadataFile {
    private static let filename = "metadata.bvf"

    /// Decrypt the metadata file for `folderURL` (or return an empty store if it doesn't exist).
    public static func load(
        from folderURL: URL,
        using session: DecryptionSession
    ) async throws -> MetadataStore {
        let url = folderURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return MetadataStore()
        }
        let plaintext = try await session.decrypt(contentsOf: url).data
        let entries = try JSONDecoder().decode([String: EntryMetadata].self, from: plaintext)
        var store = MetadataStore()
        store.entries = entries
        return store
    }

    /// Encode and encrypt `store` to a temp file, then atomically replace the existing `metadata.bvf` in `folderURL`.
    public static func save(
        _ store: MetadataStore,
        to folderURL: URL,
        publicKeyURL: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let plaintext = try encoder.encode(store.entries)

        let destination = folderURL.appendingPathComponent(filename)
        let tmpDir = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destination,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let tmp = tmpDir.appendingPathComponent(filename)
        let crypto = CryptoService()
        try crypto.encryptDataToFile(plaintext: plaintext, publicKeyURL: publicKeyURL, outputPath: tmp)
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmp)
    }
}
