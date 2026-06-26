import Foundation

@MainActor
final class iCloudFileWatcher {
    private let predicate: NSPredicate
    private let onChange: @MainActor () -> Void

    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(predicate: NSPredicate, onChange: @MainActor @escaping () -> Void) {
        self.predicate = predicate
        self.onChange = onChange
    }

    func start() {
        guard query == nil else { return }

        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        q.predicate = predicate

        let gatheringObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: q,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onChange() }
        }

        let updateObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: q,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            guard Self.shouldYield(forUserInfo: notification.userInfo) else { return }
            Task { @MainActor in self.onChange() }
        }

        observers.append(gatheringObserver)
        observers.append(updateObserver)

        q.start()
        query = q
    }

    func stop() {
        query?.stop()
        query = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    /// Decide whether an update notification represents work the consumer needs to act on.
    /// Removes-only updates (e.g., from our own iCloud cleanup phase) are suppressed.
    /// Fail-safe: when userInfo shape is unexpected, yield anyway — an extra no-op sync
    /// is much cheaper than a missed file.
    nonisolated static func shouldYield(forUserInfo userInfo: [AnyHashable: Any]?) -> Bool {
        guard let userInfo else { return true }
        let addedCount = (userInfo[NSMetadataQueryUpdateAddedItemsKey] as? [Any])?.count
        let changedCount = (userInfo[NSMetadataQueryUpdateChangedItemsKey] as? [Any])?.count
        let removedCount = (userInfo[NSMetadataQueryUpdateRemovedItemsKey] as? [Any])?.count
        if addedCount == nil && changedCount == nil && removedCount == nil { return true }
        if (addedCount ?? 0) > 0 || (changedCount ?? 0) > 0 { return true }
        return false
    }
}
