import Foundation

/// Resolves and monitors the shared iCloud container used across BVF apps.
@Observable
@MainActor
public class iCloudManager {
    /// True once the container has been resolved and the app subdirectory exists.
    public var isAvailable = false
    /// Root URL of the iCloud ubiquity container, when available.
    public var containerURL: URL?

    @ObservationIgnored public let containerIdentifier: String
    @ObservationIgnored private let appSubdirectory: String
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    /// Create a manager bound to `appSubdirectory` within the named ubiquity `container`.
    public init(_ appSubdirectory: String, container: String) {
        self.appSubdirectory = appSubdirectory
        self.containerIdentifier = container
    }

    /// Initialize iCloud container with retry logic for iOS timing issues
    /// Call this from .task { } in your root view to ensure container is ready
    public func initialize() async {
        let maxAttempts = BvfAppKitConfig.iCloudRetryAttempts
        for attempt in 1...maxAttempts {
            if await checkAvailability() {
                break
            }

            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }

        // Monitor for iCloud account/availability changes at OS level
        observer = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.recheckAvailability()
            }
        }
    }

    private func checkAvailability() async -> Bool {
        guard let url = FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier) else {
            return false
        }
        do {
            try createDirectoryStructure(base: url)
            containerURL = url
            isAvailable = true
            return true
        } catch {
            return false
        }
    }

    private func recheckAvailability() async {
        let available = await checkAvailability()
        if !available {
            isAvailable = false
            containerURL = nil
        }
    }

    private func createDirectoryStructure(base: URL) throws {
        #if DEBUG
        let appPath = "Documents/\(appSubdirectory)-DEBUG"
        let sharedPath = "Documents/Shared-DEBUG"
        #else
        let appPath = "Documents/\(appSubdirectory)"
        let sharedPath = "Documents/Shared"
        #endif

        let directories = [
            base.appendingPathComponent("\(sharedPath)/keys"),
            base.appendingPathComponent(appPath)
        ]

        for dir in directories {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
    }

    /// Shared public key location (for all apps using this container)
    public var sharedPublicKeyURL: URL? {
        #if DEBUG
        return containerURL?.appendingPathComponent("Documents/Shared-DEBUG/keys/public.key")
        #else
        return containerURL?.appendingPathComponent("Documents/Shared/keys/public.key")
        #endif
    }

    /// App-specific folder
    public var appFolderURL: URL? {
        #if DEBUG
        return containerURL?.appendingPathComponent("Documents/\(appSubdirectory)-DEBUG")
        #else
        return containerURL?.appendingPathComponent("Documents/\(appSubdirectory)")
        #endif
    }

    /// Get folder URL for a sibling app in the shared container
    public func siblingAppFolderURL(for appName: String) -> URL? {
        #if DEBUG
        return containerURL?.appendingPathComponent("Documents/\(appName)-DEBUG")
        #else
        return containerURL?.appendingPathComponent("Documents/\(appName)")
        #endif
    }

    /// Display path for app folder (for UI)
    public var appFolderPath: String {
        #if DEBUG
        return "Documents/\(appSubdirectory)-DEBUG/"
        #else
        return "Documents/\(appSubdirectory)/"
        #endif
    }
}
