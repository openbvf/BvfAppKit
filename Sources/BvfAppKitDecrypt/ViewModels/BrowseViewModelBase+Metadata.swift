import Foundation

extension BrowseViewModelBase {
    func loadMetadata(using session: DecryptionSession) async {
        guard let folder = fileAccessManager.savedFolderURL else { return }
        do {
            metadata = try await MetadataFile.load(from: folder, using: session)
            metadataLoaded = true
        } catch {
            metadataLoaded = false
            responseMessage = ResponseMessage(
                "Failed to load tags", type: .error,
                detail: error.localizedDescription
            )
        }
    }

    func clearMetadata() {
        metadata = MetadataStore()
        metadataLoaded = false
    }

    /// Set tags for the given dates and persist. Reverts in-memory state on save failure.
    public func setTags(_ tags: [String], for dates: [Date]) {
        mutateAndPersist { $0.setTags(tags, for: dates) }
    }
    /// Add a tag to each of the given dates and persist. Reverts on save failure.
    public func addTag(_ tag: String, to dates: [Date]) {
        mutateAndPersist { $0.addTag(tag, to: dates) }
    }
    /// Remove a tag from each of the given dates and persist. Reverts on save failure.
    public func removeTag(_ tag: String, from dates: [Date]) {
        mutateAndPersist { $0.removeTag(tag, from: dates) }
    }
    /// Attach source provenance to an imported entry and persist. Reverts on save failure.
    public func setSource(_ source: SourceInfo, for date: Date) {
        mutateAndPersist { $0.setSource(source, for: date) }
    }
    /// Drop all metadata for the given dates and persist. Reverts on save failure.
    public func removeMetadata(for dates: [Date]) {
        mutateAndPersist { $0.remove(for: dates) }
    }
    /// Re-key metadata when an entry's timestamp changes and persist. Reverts on save failure.
    public func moveMetadata(from oldDate: Date, to newDate: Date) {
        mutateAndPersist { $0.move(from: oldDate, to: newDate) }
    }

    private func mutateAndPersist(_ mutate: (inout MetadataStore) -> Void) {
        let snapshot = metadata
        mutate(&metadata)
        do {
            try persistMetadataThrowing()
        } catch {
            metadata = snapshot
            responseMessage = ResponseMessage(
                "Failed to save tags", type: .error,
                detail: error.localizedDescription
            )
        }
    }

    func persistMetadataBatch(beforeBatch snapshot: MetadataStore) {
        do {
            try persistMetadataThrowing()
        } catch {
            metadata = snapshot
            responseMessage = ResponseMessage(
                "Failed to save tags", type: .error,
                detail: error.localizedDescription
            )
        }
    }

    func persistMetadataThrowing() throws {
        guard metadataLoaded else {
            throw MetadataSaveError.notLoaded
        }
        guard let folder = fileAccessManager.savedFolderURL,
              let key = fileAccessManager.publicKeyURL else {
            throw MetadataSaveError.notConfigured
        }
        try MetadataFile.save(metadata, to: folder, publicKeyURL: key)
    }
}

private enum MetadataSaveError: LocalizedError {
    case notLoaded, notConfigured
    var errorDescription: String? {
        switch self {
        case .notLoaded:    "Metadata not loaded"
        case .notConfigured: "Folder or public key not configured"
        }
    }
}
