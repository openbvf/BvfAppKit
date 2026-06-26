import SwiftUI

/// Container that constructs and holds the shared BvfAppKit managers for an app.
@MainActor
public final class BvfAppKitEnvironment {
    /// iCloud container manager.
    public let cloudManager: iCloudManager
    /// Security-scoped bookmark manager for the data folder and private key.
    public let fileAccessManager: FileAccessManager
    /// File sync coordinator (macOS).
    public let syncManager: SyncManager
    /// Maintains the shared public key in iCloud.
    public let pubkeyDistributor: PubkeyDistributor
    /// Persistent user settings.
    public let appSettings: AppSettings

    /// Create the environment with the app's iCloud subdirectory, container, and app-group identifier.
    public init(
        app appSubdirectory: String,
        container: String,
        appGroupIdentifier: String
    ) {
        let cloud = iCloudManager(appSubdirectory, container: container)
        let fileAccess = FileAccessManager(cloudManager: cloud, appGroupIdentifier: appGroupIdentifier)
        let sync = SyncManager(cloudManager: cloud, fileAccessManager: fileAccess)
        let pubkey = PubkeyDistributor(cloudManager: cloud, fileAccessManager: fileAccess)
        let settings = AppSettings()

        self.cloudManager = cloud
        self.fileAccessManager = fileAccess
        self.syncManager = sync
        self.pubkeyDistributor = pubkey
        self.appSettings = settings
    }

    /// Initialize iCloud, refresh the public key, and start sync watching.
    public func initialize() async {
        await cloudManager.initialize()
        pubkeyDistributor.update()
        syncManager.updateWatchingState()
    }

}

extension View {
    /// Inject the BvfAppKit environment objects and wire up pubkey-mismatch alerts.
    public func bvfAppKitEnvironment(_ env: BvfAppKitEnvironment) -> some View {
        self
            .environment(env.cloudManager)
            .environment(env.fileAccessManager)
            .environment(env.syncManager)
            .environment(env.pubkeyDistributor)
            .environment(env.appSettings)
            .onChange(of: env.cloudManager.isAvailable) { env.pubkeyDistributor.update() }
            .onChange(of: env.fileAccessManager.publicKeyURL) { env.pubkeyDistributor.update() }
            .alert(
                "Public Key Mismatch",
                isPresented: Binding(
                    get: { env.pubkeyDistributor.pubkeyMismatch != nil },
                    set: { if !$0 { env.pubkeyDistributor.pubkeyMismatch = nil } }
                )
            ) {
                Button("Overwrite iCloud Key") { try? env.pubkeyDistributor.confirmOverwrite() }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The iCloud public key differs from your local key. This may indicate key tampering or a failed key rotation.")
            }
    }
}
