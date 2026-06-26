import Foundation
import AppKit

/// Orchestrates iCloud → local sync: watches the iCloud folder, queues syncs, and reports progress and results to the UI.
@MainActor
@Observable
public final class SyncManager {
    /// True while the iCloud file watcher is active.
    public private(set) var isWatching = false
    /// True while a sync iteration is in flight.
    public var isSyncing = false
    /// Fractional progress of the current sync (0.0–1.0).
    public var progress: Double = 0
    /// Human-readable status for the current sync step.
    public var statusMessage = ""
    /// Result/error from the most recent sync run, surfaced to the UI.
    public var lastSyncMessage: ResponseMessage?
    /// Running count of files copied or cleaned in this app session.
    public var sessionFilesCopied: Int = 0
    /// Whether iCloud sync is enabled. Persisted to `UserDefaults` and triggers watch state on change.
    public var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "iCloudSyncEnabled")
            updateWatchingState()
        }
    }
    /// Timestamp of the last successful sync, persisted to `UserDefaults`.
    public var lastSyncDate: Date? {
        didSet {
            if let date = lastSyncDate {
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: "lastSyncDate")
            } else {
                UserDefaults.standard.removeObject(forKey: "lastSyncDate")
            }
        }
    }

    /// iCloud container manager used to resolve the sync source folder.
    @ObservationIgnored public let cloudManager: iCloudManager
    /// File access manager used to resolve the local destination folder.
    @ObservationIgnored public let fileAccessManager: FileAccessManager

    @ObservationIgnored private let syncService = SyncService()
    @ObservationIgnored private var fileWatcher: iCloudFileWatcher?
    @ObservationIgnored private var streamContinuation: AsyncStream<Void>.Continuation?
    @ObservationIgnored private var consumerTask: Task<Void, Never>?
    @ObservationIgnored private var currentIterTask: Task<SyncResult, Error>?

    /// Create a sync manager. Restores `isEnabled` and `lastSyncDate` from `UserDefaults`.
    public init(cloudManager: iCloudManager, fileAccessManager: FileAccessManager) {
        self.cloudManager = cloudManager
        self.fileAccessManager = fileAccessManager

        self.isEnabled = UserDefaults.standard.bool(forKey: "iCloudSyncEnabled")
        let timestamp = UserDefaults.standard.double(forKey: "lastSyncDate")
        self.lastSyncDate = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    /// Reconcile the watcher's state with current `isEnabled` and iCloud availability.
    public func updateWatchingState() {
        if isEnabled && cloudManager.isAvailable {
            startWatching(localFolder: fileAccessManager.savedFolderURL)
        } else {
            stopWatching()
        }
    }

    /// Begin watching the iCloud folder for changes and run an initial sync. No-op if sync is disabled.
    public func startWatching(localFolder: URL?) {
        guard isEnabled else { return }
        guard cloudManager.isAvailable, let appFolder = cloudManager.appFolderURL else {
            lastSyncMessage = ResponseMessage("Cannot sync: iCloud unavailable", type: .error)
            return
        }
        guard let local = localFolder else {
            lastSyncMessage = ResponseMessage("Cannot sync: select a data folder", type: .error)
            return
        }

        stopWatching()

        let predicate = NSPredicate(
            format: "%K LIKE '*.bvf' AND %K BEGINSWITH %@",
            NSMetadataItemFSNameKey,
            NSMetadataItemPathKey,
            appFolder.path
        )

        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        streamContinuation = continuation

        let watcher = iCloudFileWatcher(predicate: predicate) { [continuation] in
            continuation.yield()
        }

        fileWatcher = watcher
        watcher.start()
        isWatching = true

        consumerTask = Task { @MainActor [weak self] in
            for await _ in stream {
                guard let self = self else { return }
                await self.runSync(to: local)
            }
        }

        // Belt-and-suspenders initial-sync trigger alongside NSMetadataQueryDidFinishGathering.
        // The bounded-1 buffer collapses both into at most one extra scan.
        continuation.yield()
    }

    /// Tear down the watcher and cancel any in-flight sync iteration.
    public func stopWatching() {
        streamContinuation?.finish()
        streamContinuation = nil

        currentIterTask?.cancel()
        currentIterTask = nil

        consumerTask?.cancel()
        consumerTask = nil

        fileWatcher?.stop()
        fileWatcher = nil

        isWatching = false
    }

    /// Cancel the currently-running sync iteration, if any.
    public func cancelSync() {
        currentIterTask?.cancel()
    }

    /// Stop watching, clear persistent sync state, and zero the session counters.
    public func reset() {
        stopWatching()
        isEnabled = false
        lastSyncDate = nil
        lastSyncMessage = nil
        sessionFilesCopied = 0
    }

    private func runSync(to localFolder: URL) async {
        guard isEnabled else { return }
        guard let iCloudFolder = cloudManager.appFolderURL else {
            lastSyncMessage = ResponseMessage("Cannot sync: iCloud unavailable", type: .error)
            return
        }

        let iter = Task { @MainActor [syncService] in
            try await syncService.sync(
                from: iCloudFolder,
                to: localFolder
            ) { [weak self] message, progressValue in
                await MainActor.run {
                    self?.statusMessage = message
                    self?.progress = progressValue
                }
            }
        }
        currentIterTask = iter

        isSyncing = true
        statusMessage = "Starting sync..."
        progress = 0.0

        do {
            let result = try await iter.value
            lastSyncDate = Date()
            sessionFilesCopied += result.filesCopied + result.orphansCleaned
            let didWork = result.filesCopied > 0
                || result.orphansCleaned > 0
                || !result.errors.isEmpty
            if didWork {
                lastSyncMessage = message(for: result)
            }
        } catch is CancellationError {
        } catch {
            lastSyncMessage = ResponseMessage(
                "Sync failed: \(error.localizedDescription)",
                type: .error
            )
        }

        currentIterTask = nil
        isSyncing = false
    }

    private func message(for result: SyncResult) -> ResponseMessage {
        if result.errors.isEmpty {
            return ResponseMessage("\(sessionFilesCopied) files synced", type: .success)
        }
        let runSynced = result.filesCopied + result.orphansCleaned
        let header = "\(runSynced) synced — \(result.errors.count) errors"
        let failures = result.errors.map { (path, desc) in
            FileFailure(url: URL(fileURLWithPath: path), errorDescription: desc)
        }
        let detail = ResponseMessage.buildErrorDetails(header: header, failures: failures)
        return ResponseMessage(header, type: .error, detail: detail)
    }
}
