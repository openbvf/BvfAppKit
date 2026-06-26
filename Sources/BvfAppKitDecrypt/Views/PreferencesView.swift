import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Shared BVF infrastructure preferences (keys, folder, iCloud sync).
/// Displayed in the Preferences window (Cmd+,) while app-specific settings stay in the in-app Settings tab.
public struct PreferencesView<AppSpecific: View>: View {
    @Environment(FileAccessManager.self) private var fileAccessManager
    @Environment(SyncManager.self) private var syncManager
    @Environment(AppSettings.self) private var appSettings
    @Environment(iCloudManager.self) private var cloudManager
    @Environment(PubkeyDistributor.self) private var pubkeyDistributor

    private let cryptoService = CryptoService()

    private let appName: String
    private let appGroupIdentifier: String
    private let appSpecificSettings: AppSpecific

    @State private var isFolderPickerPresented = false
    @State private var isPrivateKeyPickerPresented = false
    @State private var isPublicKeyPickerPresented = false

    @State private var isGenerateKeysPresented = false
    @State private var showGenerateOverwriteWarning = false
    @State private var pendingGeneratePassphrase: String?

    @State private var responseMessage: ResponseMessage?
    @State private var isSyncMessageDetailPresented = false
    @State private var isHoveringSyncMessage = false

    @State private var showOnboardingWizard = false

    /// Create a preferences view. `appSpecificSettings` is rendered above the BVF infrastructure sections.
    public init(appName: String, appGroupIdentifier: String, @ViewBuilder appSpecificSettings: () -> AppSpecific) {
        self.appName = appName
        self.appGroupIdentifier = appGroupIdentifier
        self.appSpecificSettings = appSpecificSettings()
    }

    /// SwiftUI body.
    public var body: some View {
        @Bindable var syncManager = syncManager
        @Bindable var appSettings = appSettings
        Form {
            Section {
                HStack {
                    Image(systemName: fileAccessManager.isCloudWriteMode ? "cloud.fill" : "folder.fill")
                        .foregroundColor(fileAccessManager.isCloudWriteMode ? .blue : .green)
                        .font(.title2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(fileAccessManager.isCloudWriteMode ? "iCloud Write-Only Mode" : "Standard Mode")
                            .font(.headline)
                        Text(fileAccessManager.isCloudWriteMode
                             ? "Writing directly to iCloud (like iOS)"
                             : "Local encryption keys and data folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Run Setup Wizard") {
                        showOnboardingWizard = true
                    }
                }
                .padding(.vertical, 4)

                Toggle("Show advanced settings", isOn: $appSettings.showAdvancedSettings)
            }

            appSpecificSettings

            if fileAccessManager.isStandardMode {
                Section {
                    HStack(spacing: 12) {
                        Text("Security Level")
                            .font(.headline)

                        Picker("", selection: $appSettings.securityLevel) {
                            Text("Lazy").tag(SecurityLevel.lazy)
                            Text("Normal").tag(SecurityLevel.normal)
                            Text("Paranoid").tag(SecurityLevel.paranoid)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()

                        Group {
                            switch appSettings.securityLevel {
                            case .lazy:
                                Text("10 minute timeout. For casual privacy.")
                            case .normal:
                                Text("5 minute timeout. Recommended.")
                            case .paranoid:
                                Text("1 minute timeout. Clears when switching apps.")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("Enable iCloud Sync", isOn: $syncManager.isEnabled)
                        .disabled(!fileAccessManager.canEnableSync)
                        .onChange(of: syncManager.isEnabled) { _, enabled in
                            Task { @MainActor in
                                if enabled {
                                    await handleSyncEnable()
                                } else {
                                    syncManager.cancelSync()
                                    syncManager.stopWatching()
                                }
                            }
                        }

                    if syncManager.isEnabled && appSettings.showAdvancedSettings {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Container: \(cloudManager.containerIdentifier)", systemImage: "info.circle")
                                Label("Path: \(cloudManager.appFolderPath)", systemImage: "folder")
                                Label("Shared key: Documents/Shared/keys/", systemImage: "key")
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)

                            Spacer()

                            // Live status + progress (center) — visible only while syncing
                            Group {
                                if syncManager.isSyncing {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(syncManager.statusMessage)
                                            .font(.caption2)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        ProgressView(value: syncManager.progress)
                                            .progressViewStyle(.linear)
                                    }
                                }
                            }
                            .frame(width: 200)

                            Spacer()

                            VStack(alignment: .trailing, spacing: 4) {
                                HStack(spacing: 4) {
                                    Image(systemName: syncManager.isWatching ? "eye.fill" : "eye.slash.fill")
                                        .foregroundColor(syncManager.isWatching ? .green : .secondary)
                                    Text(syncManager.isWatching ? "Watching for changes" : "Not watching")
                                }
                                .font(.caption2)
                                .foregroundColor(syncManager.isWatching ? .green : .secondary)

                                if let lastSync = syncManager.lastSyncDate {
                                    Text("Last synced: \(lastSync.relativeTimeString())")
                                }
                                if let message = syncManager.lastSyncMessage {
                                    let isClickable = message.detail != nil
                                    Text(message.text)
                                        .foregroundColor(message.type.color)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .underline(isClickable && isHoveringSyncMessage)
                                        .onTapGesture {
                                            if isClickable { isSyncMessageDetailPresented = true }
                                        }
                                        .onHover { hovering in
                                            if isClickable { isHoveringSyncMessage = hovering }
                                        }
                                }
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 200, alignment: .trailing)
                        }
                        .sheet(isPresented: $isSyncMessageDetailPresented) {
                            if let message = syncManager.lastSyncMessage {
                                MessageDetailView(message: message)
                            }
                        }
                    }
                }
            }

            if appSettings.showAdvancedSettings {
                Section {
                    HStack {
                        Button("Select Private Key") {
                            isPrivateKeyPickerPresented = true
                        }
                        .fileImporter(
                            isPresented: $isPrivateKeyPickerPresented,
                            allowedContentTypes: [.item]
                        ) { result in
                            handlePrivateKeySelection(result)
                        }

                        Spacer()

                        if let file = fileAccessManager.savedFiles[FileAccessManager.privateKeyBookmarkKey] {
                            Button(action: { revealInFinder(file) }) {
                                Text(file.path)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                    .underline()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        } else if let originalPath = fileAccessManager.invalidatedPaths[FileAccessManager.privateKeyBookmarkKey] {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text("File moved or removed")
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                            .help("Original path: \(originalPath)")
                        } else {
                            Text("No file selected")
                                .foregroundStyle(.tertiary)
                        }
                    }

                    HStack {
                        Button("Select Public Key") {
                            isPublicKeyPickerPresented = true
                        }
                        .fileImporter(
                            isPresented: $isPublicKeyPickerPresented,
                            allowedContentTypes: [.item]
                        ) { result in
                            handlePublicKeySelection(result)
                        }

                        Spacer()

                        if let file = fileAccessManager.savedFiles[FileAccessManager.publicKeyBookmarkKey] {
                            Button(action: { revealInFinder(file) }) {
                                Text(file.path)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                    .underline()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        } else if let originalPath = fileAccessManager.invalidatedPaths[FileAccessManager.publicKeyBookmarkKey] {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text("File moved or removed")
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                            .help("Original path: \(originalPath)")
                        } else {
                            Text("No file selected")
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Button("Generate Keys") {
                        handleGenerateKeysRequest()
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    HStack {
                        Button("Select Data Folder") {
                            isFolderPickerPresented = true
                        }
                        .fileImporter(
                            isPresented: $isFolderPickerPresented,
                            allowedContentTypes: [.folder]
                        ) { result in
                            handleFolderSelection(result)
                        }

                        Spacer()

                        if let folder = fileAccessManager.savedFolderURL {
                            Button(action: { revealInFinder(folder) }) {
                                Text(folder.path)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                    .underline()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        } else if let originalPath = fileAccessManager.invalidatedPaths[FileAccessManager.folderBookmarkKey] {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text("Folder moved or removed")
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                            .help("Original path: \(originalPath)")
                        } else {
                            Text("No folder selected")
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Section {
                    Button("Clear All Settings", role: .destructive) {
                        syncManager.reset()
                        fileAccessManager.clearAllSettings()
                        appSettings.reset()
                        responseMessage = ResponseMessage("All settings cleared", type: .success)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            if let message = responseMessage {
                Section {
                    Text(message.text)
                        .foregroundColor(message.type.color)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .formStyle(.grouped)
        .animation(responseMessage?.type == .success ? .easeOut(duration: 0.5) : nil, value: responseMessage)
        .task(id: responseMessage) {
            guard let message = responseMessage, message.type == .success else { return }
            let messageText = message.text
            try? await Task.sleep(for: .seconds(5))
            if responseMessage?.text == messageText {
                responseMessage = nil
            }
        }
        .alert("Overwrite Existing Keys?", isPresented: $showGenerateOverwriteWarning) {
            Button("Cancel", role: .cancel) {
                pendingGeneratePassphrase = nil
            }
            Button("Generate (Overwrite)", role: .destructive) {
                isGenerateKeysPresented = true
            }
        } message: {
            Text("This will overwrite your existing keys. Back them up first!\n\nAre you absolutely sure you want to generate new keys?")
        }
        .sheet(isPresented: $isGenerateKeysPresented) {
            GenerateKeysView { result in
                Task {
                    switch result {
                    case .success(let passphrase):
                        await handleKeyGeneration(passphrase: passphrase)
                    case .failure(let error):
                        let message = "Failed to create secure passphrase: \(error.localizedDescription)"
                        responseMessage = ResponseMessage(message, type: .error)
                    }
                }
            }
        }
        .sheet(isPresented: $showOnboardingWizard) {
            OnboardingView(appName: appName, appGroupIdentifier: appGroupIdentifier)
        }
    }

    private func handleFolderSelection(_ result: Result<URL, Error>) {
        responseMessage = fileAccessManager.selectAndSaveFolder(from: result)
        syncManager.updateWatchingState()
    }

    private func handlePrivateKeySelection(_ result: Result<URL, Error>) {
        responseMessage = fileAccessManager.selectAndSavePrivateKey(from: result)
    }

    private func handlePublicKeySelection(_ result: Result<URL, Error>) {
        responseMessage = fileAccessManager.selectAndSavePublicKey(from: result)
    }

    private func handleSyncEnable() async {
        guard fileAccessManager.canEnableSync else {
            responseMessage = ResponseMessage("Select encryption keys and data folder first", type: .error)
            syncManager.isEnabled = false
            return
        }

        do {
            try pubkeyDistributor.publish()
            syncManager.isEnabled = true
            responseMessage = ResponseMessage("iCloud sync enabled", type: .success)
        } catch {
            responseMessage = ResponseMessage(error.localizedDescription, type: .error)
            syncManager.isEnabled = false
        }
    }

    private func handleGenerateKeysRequest() {
        let hasPrivateKey = fileAccessManager.savedFiles[FileAccessManager.privateKeyBookmarkKey] != nil
        let hasPublicKey = fileAccessManager.savedFiles[FileAccessManager.publicKeyBookmarkKey] != nil

        if hasPrivateKey || hasPublicKey {
            showGenerateOverwriteWarning = true
        } else {
            isGenerateKeysPresented = true
        }
    }

    @MainActor
    private func handleKeyGeneration(passphrase: String) async {
        let priPanel = NSSavePanel()
        priPanel.nameFieldStringValue = "private.key.enc"
        priPanel.message = "Save Private Key\n\nTo keep it out of iCloud, avoid folders like Documents, Desktop, or Downloads."
        priPanel.canCreateDirectories = true
        guard await priPanel.begin() == .OK, let privateKeyURL = priPanel.url else {
            responseMessage = ResponseMessage("Key generation cancelled", type: .info)
            return
        }

        let pubPanel = NSSavePanel()
        pubPanel.nameFieldStringValue = "public.key"
        pubPanel.message = "Save Public Key\n\n(Less sensitive - can be shared safely)"
        pubPanel.canCreateDirectories = true
        guard await pubPanel.begin() == .OK, let publicKeyURL = pubPanel.url else {
            responseMessage = ResponseMessage("Key generation cancelled", type: .info)
            return
        }

        do {
            let keypair = try await cryptoService.generateKeypair(passphrase: passphrase)
            try cryptoService.saveKeypairToFiles(
                keypair: keypair,
                privateKeyURL: privateKeyURL,
                publicKeyURL: publicKeyURL
            )

            fileAccessManager.saveFile(key: FileAccessManager.privateKeyBookmarkKey, url: privateKeyURL)
            fileAccessManager.saveFile(key: FileAccessManager.publicKeyBookmarkKey, url: publicKeyURL)

            responseMessage = ResponseMessage("Keys generated successfully", type: .success)
        } catch {
            responseMessage = ResponseMessage("Key generation failed: \(error.localizedDescription)", type: .error)
        }
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

extension PreferencesView where AppSpecific == EmptyView {
    /// Convenience initializer when the app has no extra settings to render.
    public init(appName: String, appGroupIdentifier: String) {
        self.init(appName: appName, appGroupIdentifier: appGroupIdentifier) { EmptyView() }
    }
}

