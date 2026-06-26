import Foundation

/// Manages security-scoped bookmarks for persistent file/folder access.
@MainActor
@Observable
public class FileAccessManager {
    /// UserDefaults key prefix used to persist the data-folder bookmark.
    public static let folderBookmarkKey = "SavedFolder"
    /// UserDefaults key prefix used to persist the private-key bookmark.
    public static let privateKeyBookmarkKey = "priKeyURL"
    /// UserDefaults key prefix used to persist the public-key bookmark.
    public static let publicKeyBookmarkKey = "pubKeyURL"

    /// Currently-configured data folder URL, if any.
    public var savedFolderURL: URL?
    /// Currently-configured file URLs keyed by bookmark key (e.g. `privateKeyBookmarkKey`).
    public var savedFiles: [String: URL] = [:]

    /// Tracks invalidated paths (key → original path) for UI messaging.
    /// When a bookmark resolves to a different path, the bookmark is cleared and the original path is stored here.
    public var invalidatedPaths: [String: String] = [:]

    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let cryptoService: CryptoService
    @ObservationIgnored private let cloudManager: iCloudManager
    @ObservationIgnored private let appGroupContainerURL: URL?

    /// Create a manager. Resolves any persisted bookmarks immediately so properties are populated before the first view renders.
    public init(
        userDefaults: UserDefaults = .standard,
        cryptoService: CryptoService = CryptoService(),
        cloudManager: iCloudManager,
        appGroupIdentifier: String
    ) {
        self.userDefaults = userDefaults
        self.cryptoService = cryptoService
        self.cloudManager = cloudManager
        self.appGroupContainerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .standardizedFileURL
        resolveBookmark(key: Self.folderBookmarkKey, isFolder: true)
        resolveBookmark(key: Self.privateKeyBookmarkKey, isFolder: false)
        if let url = savedFiles[Self.privateKeyBookmarkKey] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        resolveBookmark(key: Self.publicKeyBookmarkKey, isFolder: false)
    }

    /// Convenience accessor for the currently-configured public key URL.
    public var publicKeyURL: URL? {
        savedFiles[Self.publicKeyBookmarkKey]
    }

    /// Convenience accessor for the currently-configured private key URL.
    public var privateKeyURL: URL? {
        savedFiles[Self.privateKeyBookmarkKey]
    }

    /// True once the data folder and both key files have been configured.
    public var isConfigured: Bool {
        savedFolderURL != nil &&
        savedFiles[Self.privateKeyBookmarkKey] != nil &&
        savedFiles[Self.publicKeyBookmarkKey] != nil
    }

    /// True when the app should fall back to write-only iCloud capture (no local key, but a shared iCloud public key is present).
    public var isCloudWriteMode: Bool {
        let hasLocalSetup = savedFolderURL != nil && privateKeyURL != nil
        guard !hasLocalSetup else { return false }
        guard invalidatedPaths.isEmpty else { return false }
        guard cloudManager.isAvailable else { return false }
        guard let pubkeyURL = cloudManager.sharedPublicKeyURL else { return false }
        return FileManager.default.fileExists(atPath: pubkeyURL.path)
    }

    /// True when the app is running with local keys and folder (the inverse of cloud write-only mode).
    public var isStandardMode: Bool {
        !isCloudWriteMode
    }

    /// Minimum prerequisites for the user to turn on iCloud sync: a public key (to encrypt to), a destination folder, and an available iCloud container.
    public var canEnableSync: Bool {
        publicKeyURL != nil && savedFolderURL != nil && cloudManager.isAvailable
    }

    /// Public key URL to use when capturing new content (falls back to the shared iCloud key in write-only mode).
    public var capturePublicKeyURL: URL? {
        if isCloudWriteMode {
            return cloudManager.sharedPublicKeyURL
        }
        return publicKeyURL
    }

    /// Destination folder URL to use when capturing new content (falls back to the shared iCloud folder in write-only mode).
    public var captureFolderURL: URL? {
        if isCloudWriteMode {
            return cloudManager.appFolderURL
        }
        return savedFolderURL
    }

    /// Returns a `ResponseMessage` describing why capture is blocked, or nil if everything required is present. `folderName` is the user-facing name for the data folder (e.g. "journal folder").
    public func validateCaptureConfiguration(folderName: String) -> ResponseMessage? {
        if isCloudWriteMode {
            let hasPubKey = capturePublicKeyURL != nil
            let hasFolder = captureFolderURL != nil
            if !hasPubKey && !hasFolder {
                return ResponseMessage("iCloud Write-Only: Missing iCloud container and public key.", type: .error)
            } else if !hasPubKey {
                return ResponseMessage("iCloud Write-Only: Missing public key in iCloud shared location.", type: .error)
            } else if !hasFolder {
                return ResponseMessage("iCloud Write-Only: iCloud container unavailable.", type: .error)
            }
        } else {
            let hasPubKey = publicKeyURL != nil
            let hasFolder = captureFolderURL != nil
            if !hasPubKey && !hasFolder {
                return ResponseMessage("Missing public key and \(folderName). Configure in Settings.", type: .error)
            } else if !hasPubKey {
                return ResponseMessage("Missing public key. Configure in Settings.", type: .error)
            } else if !hasFolder {
                return ResponseMessage("Missing \(folderName). Configure in Settings.", type: .error)
            }
        }
        return nil
    }

    /// Resolve a saved bookmark for the given key into a usable URL, starting security-scoped access where required and clearing the bookmark if it can no longer be resolved or has moved.
    public func resolveBookmark(key: String, isFolder: Bool) {
        let bookmarkKey = isFolder ? Self.folderBookmarkKey + "Bookmark" : key + "Bookmark"
        let originalPathKey = isFolder ? Self.folderBookmarkKey + "OriginalPath" : key + "OriginalPath"
        let invalidationKey = isFolder ? Self.folderBookmarkKey : key

        guard let bookmark = userDefaults.data(forKey: bookmarkKey) else {
            return
        }

        let originalPath = userDefaults.string(forKey: originalPathKey)

        var isStale = false
        do {
            // App Group paths don't need security-scoped access
            let isAppGroup = originalPath.map { isAppGroupPath(URL(fileURLWithPath: $0)) } ?? false
            let options: URL.BookmarkResolutionOptions = isAppGroup ? [] : [.withSecurityScope]

            let url = try URL(resolvingBookmarkData: bookmark,
                              options: options,
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale)

            if let originalPath = originalPath, url.path != originalPath {
                userDefaults.removeObject(forKey: bookmarkKey)
                userDefaults.removeObject(forKey: originalPathKey)
                invalidatedPaths[invalidationKey] = originalPath
                return
            }

            if isAppGroup {
                if isFolder {
                    savedFolderURL = url
                } else {
                    savedFiles[key] = url
                }
                if isStale {
                    saveBookmark(for: url, isFolder: isFolder, key: isFolder ? Self.folderBookmarkKey : key, updateOriginalPath: false)
                }
            } else if url.startAccessingSecurityScopedResource() {
                if isFolder {
                    savedFolderURL = url
                } else {
                    savedFiles[key] = url
                }

                // Stale-refresh must happen after startAccessing. We do NOT update originalPath on refresh — only on explicit save.
                if isStale {
                    saveBookmark(for: url, isFolder: isFolder, key: isFolder ? Self.folderBookmarkKey : key, updateOriginalPath: false)
                }
            } else {
                userDefaults.removeObject(forKey: bookmarkKey)
                userDefaults.removeObject(forKey: originalPathKey)
                if let originalPath = originalPath {
                    invalidatedPaths[invalidationKey] = originalPath
                }
            }
        } catch {
            if let originalPath = originalPath {
                invalidatedPaths[invalidationKey] = originalPath
            }
            userDefaults.removeObject(forKey: bookmarkKey)
            userDefaults.removeObject(forKey: originalPathKey)
        }
    }

    /// Check if a URL is within an App Group container (doesn't need security-scoped access)
    private func isAppGroupPath(_ url: URL) -> Bool {
        guard let containerURL = appGroupContainerURL else { return false }
        let urlPath = url.standardizedFileURL.path
        let containerPath = containerURL.path
        return urlPath == containerPath || urlPath.hasPrefix(containerPath + "/")
    }

    /// Persist a security-scoped bookmark for `url` as the configured data folder.
    public func saveFolder(url: URL) {
        let isAppGroup = isAppGroupPath(url)

        // Stop accessing old folder (non-App Group paths only)
        if let oldURL = savedFolderURL, !isAppGroupPath(oldURL) {
            oldURL.stopAccessingSecurityScopedResource()
        }

        saveBookmark(for: url, isFolder: true, key: Self.folderBookmarkKey)

        if !isAppGroup {
            _ = url.startAccessingSecurityScopedResource()
        }

        savedFolderURL = url
    }

    /// Persist a security-scoped bookmark for `url` under the given key (typically a private or public key file).
    public func saveFile(key: String, url: URL) {
        let isAppGroup = isAppGroupPath(url)

        if let oldURL = savedFiles[key], !isAppGroupPath(oldURL) {
            oldURL.stopAccessingSecurityScopedResource()
        }

        saveBookmark(for: url, isFolder: false, key: key)

        if !isAppGroup {
            _ = url.startAccessingSecurityScopedResource()
        }

        savedFiles[key] = url
    }

    private func saveBookmark(for url: URL, isFolder: Bool, key: String, updateOriginalPath: Bool = true) {
        do {
            // App Group paths don't need security-scoped bookmarks
            let options: URL.BookmarkCreationOptions = isAppGroupPath(url) ? [] : .withSecurityScope

            let bookmark = try url.bookmarkData(options: options,
                                                 includingResourceValuesForKeys: nil,
                                                 relativeTo: nil)
            userDefaults.set(bookmark, forKey: key + "Bookmark")

            // Original path is recorded only on explicit save; stale-refresh keeps the original so we can still detect a move.
            if updateOriginalPath {
                userDefaults.set(url.path, forKey: key + "OriginalPath")
                invalidatedPaths.removeValue(forKey: key)
            }
        } catch {
        }
    }



    /// Handle folder selection with validation and bookmark saving
    /// - Parameter result: Result from file importer
    /// - Returns: ResponseMessage indicating success, warning, or error
    public func selectAndSaveFolder(from result: Result<URL, Error>) -> ResponseMessage {
        switch result {
        case .success(let url):
            // Start security-scoped resource access for .fileImporter() URLs
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return ResponseMessage("Selected path is not a valid directory", type: .error)
            }

            saveFolder(url: url)
            return ResponseMessage("Data folder selected successfully", type: .success)
        case .failure(let error):
            return ResponseMessage("Failed to select folder: \(error.localizedDescription)", type: .error)
        }
    }

    /// Handle key file selection with validation and bookmark saving
    /// - Parameters:
    ///   - result: Result from file importer
    ///   - bookmarkKey: The bookmark key to store the file under
    ///   - validate: Validation closure that throws on invalid file
    /// - Returns: ResponseMessage indicating success or error
    public func selectAndSaveKeyFile(from result: Result<URL, Error>, bookmarkKey: String, validate: (URL) throws -> Void) -> ResponseMessage {
        switch result {
        case .success(let url):
            // Start security-scoped resource access for .fileImporter() URLs
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                try validate(url)
                saveFile(key: bookmarkKey, url: url)
                return ResponseMessage("Key selected successfully", type: .success)
            } catch {
                return ResponseMessage(error.localizedDescription, type: .error)
            }
        case .failure(let error):
            return ResponseMessage("Failed to select file: \(error.localizedDescription)", type: .error)
        }
    }

    /// Handle private key selection with validation and bookmark saving
    /// - Parameter result: Result from file importer
    /// - Returns: ResponseMessage indicating success or error
    public func selectAndSavePrivateKey(from result: Result<URL, Error>) -> ResponseMessage {
        selectAndSaveKeyFile(from: result, bookmarkKey: Self.privateKeyBookmarkKey) { url in
            try cryptoService.validatePrivateKeyFile(at: url)
        }
    }

    /// Handle public key selection with validation and bookmark saving
    /// - Parameter result: Result from file importer
    /// - Returns: ResponseMessage indicating success or error
    public func selectAndSavePublicKey(from result: Result<URL, Error>) -> ResponseMessage {
        selectAndSaveKeyFile(from: result, bookmarkKey: Self.publicKeyBookmarkKey) { url in
            try cryptoService.validatePublicKeyFile(at: url)
        }
    }

    /// Release all security-scoped accesses, drop in-memory state, and wipe the persistent domain for this bundle.
    public func clearAllSettings() {
        if let folder = savedFolderURL {
            folder.stopAccessingSecurityScopedResource()
        }
        for (_, url) in savedFiles {
            url.stopAccessingSecurityScopedResource()
        }

        savedFolderURL = nil
        savedFiles.removeAll()

        if let bundleID = Bundle.main.bundleIdentifier {
            userDefaults.removePersistentDomain(forName: bundleID)
            userDefaults.synchronize()
        }
    }
}
