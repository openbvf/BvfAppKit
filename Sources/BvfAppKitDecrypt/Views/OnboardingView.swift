import SwiftUI
import AppKit

/// First-launch onboarding wizard: presents the keys checklist and optional iCloud sync step.
public struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(FileAccessManager.self) private var fileAccessManager
    @Environment(SyncManager.self) private var syncManager
    @Environment(AppSettings.self) private var appSettings
    @Environment(iCloudManager.self) private var cloudManager
    @Environment(PubkeyDistributor.self) private var pubkeyDistributor

    private let cryptoService = CryptoService()

    private let appName: String
    private let appGroupIdentifier: String

    @State private var showGenerateKeys = false
    @State private var responseMessage: ResponseMessage?
    @State private var isGeneratingKeys = false
    @State private var showIcloudOption = true

    /// Create an onboarding view bound to the app's name and App Group identifier.
    public init(appName: String, appGroupIdentifier: String) {
        self.appName = appName
        self.appGroupIdentifier = appGroupIdentifier
    }

    /// SwiftUI body.
    public var body: some View {
        @Bindable var syncManager = syncManager
        @Bindable var appSettings = appSettings
        VStack(spacing: 16) {
            if let message = responseMessage {
                Text(message.text)
                    .foregroundColor(message.type.color)
                    .font(.callout)
            }

            HStack(alignment: .top, spacing: 16) {
                if fileAccessManager.isCloudWriteMode {
                    VStack {
                        Button("iCloud Write-Only Mode") {
                            appSettings.hasSkippedOnboarding = true
                            dismiss()
                        }
                        .buttonStyle(.bordered)

                        Text("If already set up on another device")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack {
                    Button("I'll manage my keys and data") {
                        appSettings.hasSkippedOnboarding = true
                        dismiss()
                    }
                    .buttonStyle(.bordered)

                    Text("Configure manually later")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack {
                    Button("Get Started") {
                        handleGetStarted()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canDismiss)

                    if (!canDismiss) {
                        Text(" ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ScrollView {
                VStack(spacing: 24) {
                    ChecklistSection(
                        title: "Encryption Keys",
                        subtitle: hasKeys ? nil : "Required",
                        isComplete: hasKeys,
                        icon: "key.fill"
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            if hasKeys {
                                // State 1: Keys configured - show read-only configuration
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Your private key exists only on this computer. Don't lose it!")
                                        .font(.caption)
                                        .foregroundStyle(.primary)
                                        .padding(.top, 4)
                                    Text("Settings -> Advanced to inspect.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 4)
                                }
                            } else if needsReconnection {
                                // State 2: Keys exist but not configured - offer reconnection
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("Existing keys found", systemImage: "exclamationmark.circle.fill")
                                        .foregroundColor(.orange)
                                        .font(.subheadline)
                                        .fontWeight(.medium)

                                    Text("Back them up elsewhere if you want to generate new ones.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    HStack {
                                        Button("Use Existing Keys") {
                                            reconnectToExistingKeys()
                                        }
                                        .buttonStyle(.borderedProminent)

                                        Button(action: {
                                            if let keysDir = appGroupKeysDirectory {
                                                revealInFinder(keysDir)
                                            }
                                        }) {
                                            Text("Locate in Finder")
                                        }
                                    }
                                }
                            } else {
                                // State 3: No keys - show generate button or spinner

                                if isGeneratingKeys {
                                    ProgressView()
                                } else {
                                    Button("Generate Keys") {
                                        showGenerateKeys = true
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                        }
                    }

                    if showIcloudOption {
                        ChecklistSection(
                            title: "iCloud Sync",
                            subtitle: "Optional",
                            isComplete: syncManager.isEnabled,
                            icon: "cloud.fill"
                        ) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Sync with iOS devices (you can configure this later in Settings)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Toggle("Enable iCloud Sync", isOn: $syncManager.isEnabled)
                                    .disabled(!canConfigureiCloud)
                                    .onChange(of: syncManager.isEnabled) { _, enabled in
                                        if enabled {
                                            Task {
                                                await handleSyncEnable()
                                            }
                                        }
                                    }

                                if !canConfigureiCloud {
                                    Text("Complete required items first")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(40)
        .frame(width: 600, height: 450)
        .sheet(isPresented: $showGenerateKeys) {
            GenerateKeysView { result in
                Task {
                    await handleKeyGeneration(result)
                }
            }
        }
        .task(id: responseMessage) {
            guard let message = responseMessage, message.type == .success else { return }
            let messageText = message.text
            try? await Task.sleep(for: .seconds(5))
            if responseMessage?.text == messageText {
                responseMessage = nil
            }
        }
    }

    private var hasKeys: Bool {
        fileAccessManager.savedFiles[FileAccessManager.privateKeyBookmarkKey] != nil &&
        fileAccessManager.savedFiles[FileAccessManager.publicKeyBookmarkKey] != nil &&
        fileAccessManager.savedFolderURL != nil
    }

    private var containerKeysExist: Bool {
        guard let priURL = appGroupPrivateKeyURL,
              let pubURL = appGroupPublicKeyURL else {
            return false
        }

        return FileManager.default.fileExists(atPath: priURL.path) &&
               FileManager.default.fileExists(atPath: pubURL.path)
    }

    private var needsReconnection: Bool {
        !hasKeys && containerKeysExist
    }

    private var canDismiss: Bool {
        hasKeys
    }

    private var canConfigureiCloud: Bool {
        hasKeys
    }

    private var appGroupContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    private var appGroupKeysDirectory: URL? {
        appGroupContainerURL?.appendingPathComponent("keys")
    }

    private var appGroupPrivateKeyURL: URL? {
        appGroupKeysDirectory?.appendingPathComponent("private.key.enc")
    }

    private var appGroupPublicKeyURL: URL? {
        appGroupKeysDirectory?.appendingPathComponent("public.key")
    }

    private func appGroupDataDirectory() -> URL? {
        guard let url = appGroupContainerURL?.appendingPathComponent(appName) else { return nil }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func handleGetStarted() {
        dismiss()
    }

    private func reconnectToExistingKeys() {
        guard let privateKeyURL = appGroupPrivateKeyURL,
              let publicKeyURL = appGroupPublicKeyURL,
              let appDataURL = appGroupDataDirectory() else {
            responseMessage = ResponseMessage("App Group container not available", type: .error)
            return
        }

        fileAccessManager.saveFile(key: FileAccessManager.privateKeyBookmarkKey, url: privateKeyURL)
        fileAccessManager.saveFile(key: FileAccessManager.publicKeyBookmarkKey, url: publicKeyURL)
        fileAccessManager.saveFolder(url: appDataURL)

        responseMessage = ResponseMessage("Reconnected to existing keys", type: .success)

    }

    private func handleKeyGeneration(_ result: Result<String, Error>) async {
        await MainActor.run {
            isGeneratingKeys = true
        }

        defer {
            Task { @MainActor in
                isGeneratingKeys = false
            }
        }

        switch result {
        case .success(let passphrase):
            if let keysDir = appGroupKeysDirectory {
                try? FileManager.default.createDirectory(at: keysDir, withIntermediateDirectories: true)
            }

            guard let priURL = appGroupPrivateKeyURL, let pubURL = appGroupPublicKeyURL else {
                await MainActor.run {
                    responseMessage = ResponseMessage("App Group container not available", type: .error)
                }
                return
            }

            do {
                let keypair = try await cryptoService.generateKeypair(passphrase: passphrase)
                try cryptoService.saveKeypairToFiles(keypair: keypair, privateKeyURL: priURL, publicKeyURL: pubURL)

                await MainActor.run {
                    fileAccessManager.saveFile(key: FileAccessManager.privateKeyBookmarkKey, url: priURL)
                    fileAccessManager.saveFile(key: FileAccessManager.publicKeyBookmarkKey, url: pubURL)

                    if let appDataURL = appGroupDataDirectory() {
                        fileAccessManager.saveFolder(url: appDataURL)
                    } else {
                        responseMessage = ResponseMessage("Keys saved, but failed to access App Group data folder", type: .error)
                    }
                }
            } catch {
                await MainActor.run {
                    responseMessage = ResponseMessage("Key generation failed: \(error.localizedDescription)", type: .error)
                }
            }

        case .failure(let error):
            await MainActor.run {
                responseMessage = ResponseMessage("Failed to create secure passphrase: \(error.localizedDescription)", type: .error)
            }
        }
    }

    private func handleSyncEnable() async {
        guard fileAccessManager.publicKeyURL != nil,
              fileAccessManager.savedFolderURL != nil else {
            await MainActor.run {
                responseMessage = ResponseMessage("Select encryption keys and data folder first", type: .error)
                syncManager.isEnabled = false
            }
            return
        }

        do {
            try pubkeyDistributor.publish()
            await MainActor.run {
                syncManager.isEnabled = true
                responseMessage = ResponseMessage("iCloud sync enabled", type: .success)
            }
        } catch {
            await MainActor.run {
                responseMessage = ResponseMessage(error.localizedDescription, type: .error)
                syncManager.isEnabled = false
            }
        }
    }

}

private struct ChecklistSection<Content: View>: View {
    let title: String
    let subtitle: String?
    let isComplete: Bool
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(isComplete ? .green : .secondary)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.headline)

                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(subtitle == "Required" ? .red : .secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(subtitle == "Required" ? Color.red.opacity(0.1) : Color.secondary.opacity(0.1))
                                )
                        }
                    }
                }

                Spacer()

                Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isComplete ? .green : .secondary)
                    .font(.title2)
            }
            .padding(.bottom, 12)

            content
                .padding(.leading, 12)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isComplete ? Color.green.opacity(0.3) : Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}
