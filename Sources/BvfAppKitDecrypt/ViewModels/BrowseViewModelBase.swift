import SwiftUI
import Foundation
import AppKit

/// Whether selected tag filters match entries containing **any** or **all** of them.
public enum TagFilterMode {
    case any
    case all
}

/// Base class for browse view models: shared unlock flow, date range, tag filtering, selection, idle timeout, and import/export plumbing.
/// Apps subclass this to add app-specific search or content handling.
@MainActor
@Observable
open class BrowseViewModelBase: NSObject {
    /// Start of the date range to load entries from (inclusive).
    public var startDate: Date
    /// End of the date range to load entries from (inclusive).
    public var endDate: Date
    /// Currently-selected date-range preset, or nil for a custom range.
    public var selectedPreset: DateRangePreset?
    /// True while a file search or content load is in flight.
    public var isLoading = false
    /// True while passphrase-derived key derivation is in flight.
    public var isDecrypting = false
    /// Drives presentation of the unlock modal.
    public var showPassphraseModal = false
    /// Status/error message bound to the UI.
    public var responseMessage: ResponseMessage?
    /// Loaded entry dates in ascending order.
    public var dates: [Date] = []
    /// Tags the user has selected to filter by.
    public var selectedTagFilters: Set<String> = []
    /// Whether tag filters combine with `any` or `all` semantics.
    public var tagFilterMode: TagFilterMode = .any
    /// The user's current multi-selection.
    public var selectedDates: Set<Date> = []
    /// Drives presentation of the delete-confirmation alert.
    public var showDeleteConfirmation = false
    /// Drives presentation of the change-date sheet.
    public var showDatePicker = false
    /// Bound value for the change-date sheet.
    public var datePickerValue: Date = Date()
    /// Set when the unlocked key derives a public key that doesn't match the on-disk public key file.
    public var localPubkeyMismatch = false
    @ObservationIgnored private var derivedPublicKey: String?

    /// `dates` after applying tag and subclass-specific filters.
    public var filteredDates: [Date] {
        applyFilters(to: dates)
    }

    /// `filteredDates` grouped by calendar day.
    public var groupedDates: [(day: Date, dates: [Date])] {
        groupDatesByDay(filteredDates)
    }

    /// Active decryption session after unlock, or nil when locked.
    public var session: DecryptionSession?
    /// True when a session is active.
    public var isUnlocked: Bool { session != nil }

    /// Raw matching file URLs before `populate` fills `filesByDate`.
    public var files: [URL] = []
    /// Lookup from entry date to its encrypted file URL.
    public var filesByDate: [Date: URL] = [:]

    /// In-memory metadata (tags, source info) for loaded entries.
    public internal(set) var metadata = MetadataStore()
    /// True once metadata has been decrypted into `metadata`.
    public internal(set) var metadataLoaded = false

    /// Inactivity timer that triggers `clearSensitiveData` when the configured timeout elapses.
    @ObservationIgnored public let idleTimer: IdleTimer
    @ObservationIgnored private let appSettings: AppSettings
    /// Source of the configured key and folder URLs.
    @ObservationIgnored public let fileAccessManager: FileAccessManager
    /// Coordinates iCloud sync state.
    @ObservationIgnored public let syncManager: SyncManager

    /// Maximum number of files allowed in a single browse session before search is aborted.
    public var maxFiles: Int { BvfAppKitConfig.maxBrowseFiles }

    @ObservationIgnored private var selectionAnchor: Date?
    @ObservationIgnored private var unlockContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var clearRequested = false

    /// Summary of an import currently waiting for user confirmation, if any.
    public var pendingImportSummary: ImportSummary?
    @ObservationIgnored private var importContinuation: CheckedContinuation<ImportDecision, Never>?

    /// URL of the private key file. Override to source it from somewhere other than the configured `FileAccessManager`.
    open var keyURL: URL? {
        return fileAccessManager.privateKeyURL
    }
    /// URL of the data folder. Override to source it from elsewhere.
    open var folderURL: URL? {
        return fileAccessManager.savedFolderURL
    }
    /// URL of the public key file.
    open var publicKeyURL: URL? {
        return fileAccessManager.publicKeyURL
    }
    /// Human-readable name for one entry, used in UI messages. Override per app (e.g. "entries", "images").
    open var itemTypeName: String { "items" }

    /// Create a base view model for the given date range, settings, and shared managers.
    public init(startDate: Date, endDate: Date, appSettings: AppSettings, fileAccessManager: FileAccessManager, syncManager: SyncManager) {
        self.startDate = startDate
        self.endDate = endDate
        self.appSettings = appSettings
        self.fileAccessManager = fileAccessManager
        self.syncManager = syncManager
        self.idleTimer = IdleTimer(threshold: { [appSettings] in
            appSettings.securityLevel.timeoutInterval
        })
        super.init()
        self.idleTimer.onIdleAction = { [weak self] in
            Task { @MainActor in
                self?.clearSensitiveData(reason: "inactivity")
            }
        }
    }

    /// Search the configured folder for files in the current date range, then either populate (if unlocked) or prompt for the passphrase.
    public func loadEntries() async {
        guard let folderURL else {
            responseMessage = ResponseMessage("No folder configured", type: .error)
            return
        }

        selectedPreset = nil
        isLoading = true
        defer { isLoading = false }

        let range = queryRange()
        let result = await FileSearchService.findMatchingFiles(in: folderURL, dateRange: range)
        files = result.matchingFiles

        if files.isEmpty {
            responseMessage = ResponseMessage(result.summary, type: .info)
            return
        }
        if files.count > maxFiles {
            responseMessage = ResponseMessage("Too many files (\(files.count)). Narrow date range.", type: .error)
            return
        }

        if session != nil {
            populate(from: files)
        } else {
            responseMessage = nil
            showPassphraseModal = true
        }
    }

    /// The user-visible endDate is inclusive (last included day).
    /// For half-open interval queries, extend by one day.
    private func queryRange() -> DateRange {
        let calendar = Calendar.current
        let dayAfterEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate))
            ?? endDate.addingTimeInterval(86400)
        return DateRange(start: startDate, end: dayAfterEnd)
    }

    /// Returns immediately if a session is active; otherwise presents the passphrase modal and awaits the result.
    public func ensureUnlocked() async -> Bool {
        if session != nil { return true }
        return await withCheckedContinuation { continuation in
            self.unlockContinuation = continuation
            self.responseMessage = nil
            self.showPassphraseModal = true
        }
    }

    /// Cancel a parked unlock request and clear any sensitive state.
    public func handleUnlockCancel() {
        clearSensitiveData(reason: "unlock cancelled")
    }

    /// Derive the session key from `passphrase`, attach it, and load metadata. Sets `responseMessage` on failure.
    public func unlock(with passphrase: String) async {
        guard let keyURL else {
            responseMessage = ResponseMessage("No private key configured", type: .error)
            return
        }

        clearRequested = false
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        isDecrypting = true

        do {
            let cryptoService = CryptoService()
            // Move expensive key derivation off main thread
            let newSession = try await Task.detached {
                try cryptoService.createSession(keyPath: keyURL, passphrase: passphrase)
            }.value

            guard !clearRequested else {
                // Clear was requested during derivation, don't assign session
                isDecrypting = false
                return
            }
            session = newSession
            Task.detached { [publicKeyURL] in
                guard let pubKeyURL = publicKeyURL,
                      let localKey = try? readKeyFile(at: pubKeyURL),
                      !localKey.isEmpty else { return }
                let derivedKey = newSession.publicKey
                if localKey != derivedKey {
                    await MainActor.run {
                        self.derivedPublicKey = derivedKey
                        self.localPubkeyMismatch = true
                    }
                }
            }
            idleTimer.start()

            if let session {
                await loadMetadata(using: session)
            }

            showPassphraseModal = false
            // A parked continuation here means unlock was triggered mid-flow
            // (writeImportMetadata's ensureUnlocked) — that caller will re-enter
            // the import lifecycle on its own, so don't kick a second one.
            let midFlowReprompt = unlockContinuation != nil
            unlockContinuation?.resume(returning: true)
            unlockContinuation = nil
            populate(from: files)
            if !midFlowReprompt {
                Task { [weak self] in await self?.checkPendingImport() }
            }
        } catch {
            showPassphraseModal = false
            responseMessage = ResponseMessage("Failed to unlock: \(error.localizedDescription)", type: .error)
            unlockContinuation?.resume(returning: false)
            unlockContinuation = nil
        }

        isDecrypting = false
    }

    /// Overwrite the on-disk public key with the one derived from the just-unlocked private key, resolving a pubkey mismatch.
    public func replaceLocalPublicKey() {
        guard let derivedKey = derivedPublicKey,
              let pubKeyURL = publicKeyURL else { return }
        do {
            try derivedKey.write(to: pubKeyURL, atomically: true, encoding: .utf8)
            responseMessage = ResponseMessage("Local public key replaced", type: .success)
        } catch {
            responseMessage = ResponseMessage("Failed to replace public key: \(error.localizedDescription)", type: .error)
        }
        derivedPublicKey = nil
    }

    /// Validates that the session is still valid before accessing decrypted content.
    /// Returns false if too much time has elapsed since last activity, triggering a clear.
    public func validateBeforeAccess() -> Bool {
        guard session != nil else { return false }

        let threshold = appSettings.idleTimeoutInterval
        let timeSinceActivity = idleTimer.timeSinceLastActivity()

        if timeSinceActivity > threshold {
            clearSensitiveData(reason: "session timeout")
            return false
        }

        return true
    }

    /// Build the `dates` and `filesByDate` lookup from matching files. Override to add app-specific cleanup (e.g. cancel in-flight searches) before calling `super`.
    open func populate(from files: [URL]) {
        guard validateBeforeAccess() else { return }

        var dateToFile: [Date: URL] = [:]
        for url in files {
            guard let date = url.bvfDate() else { continue }
            dateToFile[date] = url
        }

        filesByDate = dateToFile
        dates = dateToFile.keys.sorted()

        responseMessage = ResponseMessage("Loaded \(dates.count) entries", type: .success)
        self.files = []
    }

    /// Apply filters to dates - subclasses can override to add custom filtering
    /// - Parameter dates: Input dates to filter
    /// - Returns: Filtered dates
    open func applyFilters(to dates: [Date]) -> [Date] {
        return filterByTag(dates)
    }

    /// Filter dates by selected tags
    public func filterByTag(_ dates: [Date]) -> [Date] {
        guard !selectedTagFilters.isEmpty else {
            return dates
        }

        return dates.filter { date in
            let entryTags = Set(metadata.tags(for: date))
            switch tagFilterMode {
            case .any:
                return !selectedTagFilters.isDisjoint(with: entryTags)
            case .all:
                return selectedTagFilters.isSubset(of: entryTags)
            }
        }
    }

    /// Handle item selection with modifier key support
    /// - Parameters:
    ///   - date: The date to select
    ///   - orderedDates: The complete ordered list of dates for range selection
    public func handleSelection(_ date: Date, in orderedDates: [Date]) {
        let modifiers = NSEvent.modifierFlags
        let isCommand = modifiers.contains(.command)
        let isShift = modifiers.contains(.shift)

        if isShift, let anchor = selectionAnchor, let startIndex = orderedDates.firstIndex(of: anchor), let endIndex = orderedDates.firstIndex(of: date) {
            let range = min(startIndex, endIndex)...max(startIndex, endIndex)
            selectedDates = Set(orderedDates[range])
        } else if isCommand {
            if selectedDates.contains(date) {
                selectedDates.remove(date)
            } else {
                selectedDates.insert(date)
            }
            selectionAnchor = date
        } else {
            selectedDates = [date]
            selectionAnchor = date
        }
    }

    /// Clear the current selection
    public func clearSelection() {
        selectedDates = []
        selectionAnchor = nil
    }

    /// Collapse selection to just this date if it isn't already part of the
    /// selection. No-op if already selected. Used by context-menu actions to
    /// guarantee the right-clicked row is included in the action's operand set.
    public func ensureExclusivelySelected(_ date: Date) {
        if !selectedDates.contains(date) {
            selectedDates = [date]
            selectionAnchor = date
        }
    }

    /// Select every entry currently in `filteredDates`.
    public func selectAll() {
        selectedDates = Set(filteredDates)
    }

    /// Tear down the session, clear all derived in-memory state, and stop the idle timer. Override to add app-specific cleanup before calling `super`.
    open func clearSensitiveData(reason: String? = nil) {
        clearRequested = true

        unlockContinuation?.resume(returning: false)
        unlockContinuation = nil
        showPassphraseModal = false

        // Resume any pending import confirmation as deferred — encrypted
        // staging is at-rest-safe (public-key only), so preserve it and let
        // the next session re-present the modal via findExistingImport.
        importContinuation?.resume(returning: .deferred)
        importContinuation = nil
        pendingImportSummary = nil

        idleTimer.stop()
        session = nil
        dates = []
        selectedTagFilters.removeAll()
        tagFilterMode = .any
        selectedDates = []
        selectionAnchor = nil
        filesByDate = [:]
        files = []
        clearMetadata()

        if let reason = reason {
            responseMessage = ResponseMessage("Session cleared due to \(reason)", type: .info)
        } else {
            responseMessage = nil
        }
    }

    /// Present the system file picker and import the selected files/folders into the configured data folder, encrypted with the public key.
    public func showImportPanel(
        fileFilter: @escaping @Sendable (URL) -> Bool,
        outputSuffix: (@Sendable (URL) -> String)? = nil,
        fileProcessor: (@Sendable (URL) throws -> Data?)? = nil
    ) async {
        // Pre-flight: if a previous import is paused, resolve it before the
        // file picker. Otherwise the user would select new files only to have
        // them silently ignored by the resume gate.
        if let folderURL = self.folderURL,
           DirectoryImportService.hasPendingImport(at: folderURL) {
            await checkPendingImport()
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Select files or folders to import"

        panel.begin { response in
            guard response == .OK else { return }
            let rootURL = Self.rootURL(forSelection: panel.urls)

            Task { @MainActor in
                guard let folderURL = self.folderURL,
                      let publicKeyURL = self.publicKeyURL else {
                    self.responseMessage = ResponseMessage("Import failed: Keys or folder not configured", type: .error)
                    return
                }
                let message = await BrowseImportExportOps.importFiles(
                    panel.urls,
                    rootURL: rootURL,
                    folderURL: folderURL,
                    publicKeyURL: publicKeyURL,
                    fileFilter: fileFilter,
                    outputSuffix: outputSuffix,
                    fileProcessor: fileProcessor,
                    confirmAction: { [weak self] summary in
                        guard let self else { return .discard }
                        return await self.awaitImportConfirmation(summary)
                    },
                    metadataWriter: { [weak self] infos in
                        guard let self else {
                            throw ImportMetadataError.viewModelDeallocated
                        }
                        try await self.writeImportMetadata(infos)
                    },
                    onProgress: { [weak self] msg in self?.responseMessage = msg }
                )
                self.responseMessage = message
            }
        }
    }

    /// Called after a successful initial unlock. If a previous import was
    /// paused or interrupted, re-present its confirmation modal.
    private func checkPendingImport() async {
        guard let folderURL = self.folderURL,
              let publicKeyURL = self.publicKeyURL,
              DirectoryImportService.hasPendingImport(at: folderURL) else { return }

        let message = await BrowseImportExportOps.importFiles(
            [],
            rootURL: nil,
            folderURL: folderURL,
            publicKeyURL: publicKeyURL,
            fileFilter: { _ in true },
            confirmAction: { [weak self] summary in
                guard let self else { return .discard }
                return await self.awaitImportConfirmation(summary)
            },
            metadataWriter: { [weak self] infos in
                guard let self else {
                    throw ImportMetadataError.viewModelDeallocated
                }
                try await self.writeImportMetadata(infos)
            },
            onProgress: { [weak self] msg in self?.responseMessage = msg }
        )
        self.responseMessage = message
    }

    /// Park the current import flow until the user resolves the confirmation modal.
    public func awaitImportConfirmation(_ summary: ImportSummary) async -> ImportDecision {
        await withCheckedContinuation { continuation in
            self.importContinuation = continuation
            self.pendingImportSummary = summary
        }
    }

    /// Resume a parked import flow with the user's decision.
    public func resolveImportConfirmation(_ decision: ImportDecision) {
        pendingImportSummary = nil
        importContinuation?.resume(returning: decision)
        importContinuation = nil
    }

    private func writeImportMetadata(_ infos: [ImportedFileInfo]) async throws {
        guard await ensureUnlocked() else {
            throw ImportMetadataError.unlockCancelled
        }
        let snapshot = metadata
        for info in infos {
            if !info.extractTags().isEmpty { metadata.setTags(info.extractTags(), for: [info.date]) }
            if info.wasProcessed, let hash = info.sourceContentHash {
                metadata.setSource(
                    SourceInfo(name: info.sourceURL.lastPathComponent, contentHash: hash),
                    for: info.date
                )
            }
        }
        persistMetadataBatch(beforeBatch: snapshot)
    }

    enum ImportMetadataError: LocalizedError {
        case unlockCancelled
        case viewModelDeallocated

        var errorDescription: String? {
            switch self {
            case .unlockCancelled: return "Unlock cancelled — metadata not saved"
            case .viewModelDeallocated: return "Import context lost"
            }
        }
    }

    private static func rootURL(forSelection urls: [URL]) -> URL? {
        guard urls.count == 1 else { return nil }
        let url = urls[0]
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        return isDirectory ? url : url.deletingLastPathComponent()
    }

    /// Delete all selected entries
    public func deleteSelected() async {
        guard !selectedDates.isEmpty else { return }
        guard let folderURL else { return }

        let snapshot = metadata
        metadata.remove(for: Array(selectedDates))
        do {
            try persistMetadataThrowing()
        } catch {
            metadata = snapshot
            responseMessage = ResponseMessage(
                "Failed to save tags", type: .error,
                detail: error.localizedDescription
            )
            return
        }

        let capturedSelected = selectedDates
        let capturedFilesByDate = filesByDate
        let result = await Task.detached {
            BrowseFileOps.deleteFiles(
                at: capturedSelected, filesByDate: capturedFilesByDate,
                folderURL: folderURL
            )
        }.value
        for date in result.deletedDates {
            filesByDate[date] = nil
            if let i = dates.firstIndex(of: date) { dates.remove(at: i) }
        }
        selectedDates = []
        if result.failures.isEmpty {
            responseMessage = ResponseMessage(
                "Deleted \(result.deletedDates.count) entries", type: .success
            )
        } else {
            let header = "Deleted \(result.deletedDates.count), \(result.failures.count) failed"
            let detail = ResponseMessage.buildErrorDetails(header: header, failures: result.failures)
            responseMessage = ResponseMessage(header, type: .error, detail: detail)
        }
    }

    /// Change the date of selected entries
    /// - Parameters:
    ///   - dates: Set of dates to move
    ///   - newDate: Target date
    public func changeDate(for dates: Set<Date>, to newDate: Date) async {
        guard let folderURL else { return }
        let capturedFilesByDate = filesByDate
        let result = await Task.detached {
            BrowseFileOps.changeDates(
                for: dates, to: newDate,
                filesByDate: capturedFilesByDate, folderURL: folderURL
            )
        }.value
        let snapshot = metadata
        for move in result.moves {
            metadata.move(from: move.oldDate, to: move.newDate)
        }
        persistMetadataBatch(beforeBatch: snapshot)
        for move in result.moves {
            filesByDate[move.oldDate] = nil
            if let i = self.dates.firstIndex(of: move.oldDate) { self.dates.remove(at: i) }
            filesByDate[move.newDate] = move.newURL
            self.dates.append(move.newDate)
        }
        self.dates.sort()
        selectedDates = []
        if result.failures.isEmpty {
            responseMessage = ResponseMessage(
                "Moved \(result.moves.count) entries", type: .success
            )
        } else {
            let header = "Moved \(result.moves.count), \(result.failures.count) failed"
            let detail = ResponseMessage.buildErrorDetails(header: header, failures: result.failures)
            responseMessage = ResponseMessage(header, type: .error, detail: detail)
        }
    }

    /// Prompt for a destination folder, then decrypt and export the currently-selected entries.
    public func exportSelected() async {
        guard let session = session else {
            responseMessage = ResponseMessage("No active session", type: .error)
            return
        }

        guard !selectedDates.isEmpty else {
            responseMessage = ResponseMessage("No \(itemTypeName) selected", type: .error)
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let selectedFiles = selectedDates.compactMap { filesByDate[$0] }

        responseMessage = await BrowseImportExportOps.exportFiles(
            urls: selectedFiles,
            to: destination,
            session: session
        )
    }

}
