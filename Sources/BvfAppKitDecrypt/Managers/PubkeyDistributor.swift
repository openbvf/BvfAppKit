import Foundation
import CryptoKit

/// Describes a divergence between the local public key file and the one published to iCloud.
public struct PubkeyMismatch {
    /// URL of the local public key file.
    public let localURL: URL
    /// URL of the public key file currently in the iCloud shared location.
    public let remoteURL: URL
}

/// Publishes the local public key to the shared iCloud location and watches for remote changes that would mismatch it.
@MainActor
@Observable
public final class PubkeyDistributor {
    @ObservationIgnored private let cloudManager: iCloudManager
    @ObservationIgnored private let fileAccessManager: FileAccessManager
    @ObservationIgnored private var watcher: iCloudFileWatcher?

    /// Most recently observed mismatch between local and remote public keys, or nil if they match.
    public var pubkeyMismatch: PubkeyMismatch?

    /// Create a distributor bound to the given iCloud and file-access managers.
    public init(cloudManager: iCloudManager, fileAccessManager: FileAccessManager) {
        self.cloudManager = cloudManager
        self.fileAccessManager = fileAccessManager
    }

    /// Start (or stop) watching the remote pubkey, depending on current iCloud availability and local configuration.
    public func update() {
        guard cloudManager.isAvailable,
              fileAccessManager.publicKeyURL != nil,
              let remoteURL = cloudManager.sharedPublicKeyURL else {
            watcher?.stop()
            watcher = nil
            pubkeyMismatch = nil
            return
        }

        if watcher == nil {
            let predicate = NSPredicate(
                format: "%K == %@",
                NSMetadataItemPathKey,
                remoteURL.path
            )
            let w = iCloudFileWatcher(predicate: predicate) { [weak self] in
                try? self?.publish()
            }
            watcher = w
            w.start()
        }

        do {
            try publish()
        } catch {}
    }

    /// Upload the local pubkey if missing remotely, or set `pubkeyMismatch` if the remote one differs. Throws on I/O failure.
    public func publish() throws {
        guard cloudManager.isAvailable,
              let localURL = fileAccessManager.publicKeyURL,
              let remoteURL = cloudManager.sharedPublicKeyURL else {
            return
        }

        if !FileManager.default.fileExists(atPath: remoteURL.path) {
            try upload(local: localURL, remote: remoteURL)
            pubkeyMismatch = nil
            return
        }

        if try matches(local: localURL, remote: remoteURL) {
            pubkeyMismatch = nil
            return
        }

        pubkeyMismatch = PubkeyMismatch(localURL: localURL, remoteURL: remoteURL)
    }

    /// User-confirmed: overwrite the remote pubkey with the local one and clear the mismatch.
    public func confirmOverwrite() throws {
        guard let mismatch = pubkeyMismatch else { return }
        try upload(local: mismatch.localURL, remote: mismatch.remoteURL)
        pubkeyMismatch = nil
    }

    private func upload(local: URL, remote: URL) throws {
        let didStartAccess = local.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                local.stopAccessingSecurityScopedResource()
            }
        }
        let localData = try Data(contentsOf: local)
        try FileManager.default.createDirectory(
            at: remote.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try localData.write(to: remote, options: .atomic)
    }

    private func matches(local: URL, remote: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: remote.path) else {
            return false
        }
        let didStartAccess = local.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                local.stopAccessingSecurityScopedResource()
            }
        }
        let localData = try Data(contentsOf: local)
        let remoteData = try Data(contentsOf: remote)
        return SHA256.hash(data: localData) == SHA256.hash(data: remoteData)
    }
}
