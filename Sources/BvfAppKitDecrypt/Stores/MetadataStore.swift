import Foundation

/// Provenance for an imported entry: the original filename and a content hash for duplicate detection.
public struct SourceInfo: Codable, Sendable {
    /// Original filename at import time.
    public var name: String
    /// SHA-256 (or equivalent) of the source content, used for duplicate detection.
    public var contentHash: String

    /// Create a `SourceInfo` with the given name and hash.
    public init(name: String, contentHash: String) {
        self.name = name
        self.contentHash = contentHash
    }
}

/// Per-entry metadata: tags and optional import provenance.
public struct EntryMetadata: Codable, Sendable {
    /// Tags assigned to this entry.
    public var tags: [String]
    /// Source provenance, if the entry was imported.
    public var source: SourceInfo?

    /// Create entry metadata.
    public init(tags: [String] = [], source: SourceInfo? = nil) {
        self.tags = tags
        self.source = source
    }

    var isEmpty: Bool {
        tags.isEmpty && source == nil
    }
}

/// In-memory metadata for a session: maps entry path-keys to per-entry metadata.
public struct MetadataStore: Sendable {
    package var entries: [String: EntryMetadata] = [:]

    /// Create an empty store.
    public init() {}

    private func key(for date: Date) -> String {
        date.filePathString
    }

    /// Return tags for the entry at `date`, or an empty array if none.
    public func tags(for date: Date) -> [String] {
        return entries[key(for: date)]?.tags ?? []
    }

    /// Return all unique tags across every entry, sorted.
    public func allTags() -> [String] {
        var uniqueTags = Set<String>()
        for entry in entries.values {
            uniqueTags.formUnion(entry.tags)
        }
        return uniqueTags.sorted()
    }

    /// Replace the tag list for each of `dates`. Entries with empty tags and no source are removed.
    public mutating func setTags(_ tags: [String], for dates: [Date]) {
        for date in dates {
            let k = key(for: date)
            var entry = entries[k] ?? EntryMetadata()
            entry.tags = tags
            entries[k] = entry.isEmpty ? nil : entry
        }
    }

    /// Add `tag` to each of `dates` if not already present.
    public mutating func addTag(_ tag: String, to dates: [Date]) {
        for date in dates {
            let k = key(for: date)
            var entry = entries[k] ?? EntryMetadata()
            if !entry.tags.contains(tag) {
                entry.tags.append(tag)
                entries[k] = entry
            }
        }
    }

    /// Remove `tag` from each of `dates`. Entries with no remaining metadata are dropped.
    public mutating func removeTag(_ tag: String, from dates: [Date]) {
        for date in dates {
            let k = key(for: date)
            guard var entry = entries[k] else { continue }
            entry.tags.removeAll { $0 == tag }
            entries[k] = entry.isEmpty ? nil : entry
        }
    }

    /// Attach source provenance to the entry at `date`.
    public mutating func setSource(_ source: SourceInfo, for date: Date) {
        let k = key(for: date)
        var entry = entries[k] ?? EntryMetadata()
        entry.source = source
        entries[k] = entry
    }

    /// Drop all metadata for the given dates.
    public mutating func remove(for dates: [Date]) {
        for date in dates {
            entries[key(for: date)] = nil
        }
    }

    /// Re-key the metadata at `oldDate` to `newDate` (used when an entry's timestamp changes).
    public mutating func move(from oldDate: Date, to newDate: Date) {
        let oldKey = key(for: oldDate)
        let newKey = key(for: newDate)
        if let existing = entries[oldKey] {
            entries[newKey] = existing
            entries[oldKey] = nil
        }
    }
}
