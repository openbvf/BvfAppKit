import Foundation

/// Central configuration for tunable operational parameters across BvfAppKit.
public enum BvfAppKitConfig {
    /// Maximum files allowed per browse query.
    public static let maxBrowseFiles = 50_000

    /// Max concurrent decryption operations. Matches active CPU count: decryption
    /// is CPU-bound (AEAD), and Apple Silicon runs one thread per core, so the
    /// cooperative pool can't parallelize beyond this anyway.
    public static let decryptionConcurrencyLimit = ProcessInfo.processInfo.activeProcessorCount

    /// Debounce delay before starting lazy decryption on scroll (milliseconds).
    public static let decryptionDebounceMs = 200

    /// Idle timer polling interval (seconds).
    public static let idleTimerPollingInterval: TimeInterval = 5.0

    /// Max wait time for iCloud file download (seconds).
    public static let iCloudDownloadTimeout: TimeInterval = 300.0

    /// Number of iCloud container initialization attempts.
    public static let iCloudRetryAttempts = 3

    /// Report import progress every N files.
    public static let importProgressInterval = 100

    /// Max error entries to display in summary messages.
    public static let maxErrorEntries = 100
}
