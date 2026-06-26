import SwiftUI

import AppKit

/// Adds the shared browse modal sheets and system clear-on-X observers to any `View`.
public extension View {
    /// Attach the shared modal sheets (passphrase, tags, delete confirmation, change-date, import) and system clear-on-X observers.
    func browseModals<VM: BrowseViewModelBase>(
        viewModel: VM,
        showTagSheet: Binding<Bool>
    ) -> some View {
        self.modifier(BrowseModalsModifier(viewModel: viewModel, showTagSheet: showTagSheet))
    }
}

private struct BrowseModalsModifier<VM: BrowseViewModelBase>: ViewModifier {
    @Bindable var viewModel: VM
    @Binding var showTagSheet: Bool
    @Environment(FileAccessManager.self) var fileAccessManager
    @Environment(AppSettings.self) var appSettings

    func body(content: Content) -> some View {
        if !fileAccessManager.isConfigured {
            Text("Configure keys and data folder in Preferences (⌘,)")
        } else {
            content
                .id(viewModel.isUnlocked)
            .sheet(isPresented: $viewModel.showPassphraseModal) {
                PassphraseModalView(
                    isPresented: $viewModel.showPassphraseModal,
                    isLoading: $viewModel.isDecrypting,
                    onDecrypt: { passphrase in
                        await viewModel.unlock(with: passphrase)
                    },
                    onCancel: {
                        viewModel.files = []
                        viewModel.responseMessage = nil
                        viewModel.handleUnlockCancel()
                    }
                )
            }
            .sheet(isPresented: $showTagSheet) {
                TagManagementSheet(
                    selectedDates: viewModel.selectedDates,
                    viewModel: viewModel,
                    onDismiss: { showTagSheet = false }
                )
            }
            .confirmationDialog(
                "Delete \(viewModel.selectedDates.count) \(viewModel.selectedDates.count == 1 ? "entry" : "entries")?",
                isPresented: $viewModel.showDeleteConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task { await viewModel.deleteSelected() }
                }
            }
            .sheet(isPresented: $viewModel.showDatePicker) {
                ChangeDateSheet(viewModel: viewModel, isPresented: $viewModel.showDatePicker)
            }
            .sheet(item: $viewModel.pendingImportSummary) { summary in
                ImportConfirmationModal(summary: summary) { decision in
                    viewModel.resolveImportConfirmation(decision)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                // Clear decrypted data when app is quitting
                viewModel.clearSensitiveData(reason: "app termination")
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
                // Clear decrypted data before system sleep to prevent plaintext in hibernation file
                viewModel.clearSensitiveData(reason: "system sleep")
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in
                // Clear on fast user switch or screen lock
                viewModel.clearSensitiveData(reason: "session resign")
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)) { _ in
                // Clear on display sleep, lid close, hot corner
                viewModel.clearSensitiveData(reason: "screen sleep")
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willPowerOffNotification)) { _ in
                // Clear on shutdown/restart
                viewModel.clearSensitiveData(reason: "power off")
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                _ = viewModel.validateBeforeAccess()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                // Clear when app loses focus (paranoid mode only)
                if appSettings.clearsOnAppResign {
                    viewModel.clearSensitiveData(reason: "app resign")
                }
            }
            .alert("Local Public Key Mismatch",
                   isPresented: $viewModel.localPubkeyMismatch) {
                Button("Replace") {
                    viewModel.replaceLocalPublicKey()
                }
                Button("Ignore", role: .cancel) {}
            } message: {
                Text("Your local public key file doesn't match the key derived from your private key. New captures may encrypt to the wrong key.")
            }
        }
    }
}
