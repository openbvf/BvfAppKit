import SwiftUI

/// Modal for secure passphrase entry. Reusable; takes bindings for UI state and closures for unlock/cancel actions.
struct PassphraseModalView: View {
    @Binding var isPresented: Bool
    @Binding var isLoading: Bool

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isPassphraseFieldFocused: Bool

    /// Callback invoked when user submits passphrase
    var onDecrypt: (String) async -> Void

    /// Callback invoked when user cancels operation
    var onCancel: () -> Void

    @State private var passphrase: String = ""

    init(
        isPresented: Binding<Bool>,
        isLoading: Binding<Bool>,
        onDecrypt: @escaping (String) async -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._isPresented = isPresented
        self._isLoading = isLoading
        self.onDecrypt = onDecrypt
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Unlock")
                .font(.headline)

            // Use ZStack with opacity instead of conditional rendering to prevent
            // structural view changes during modal dismissal (prevents layout recursion)
            ZStack {
                SecureField("Enter your passphrase", text: $passphrase)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .focused($isPassphraseFieldFocused)
                    .onSubmit {
                        Task {
                            await handlePassphrase()
                        }
                    }
                    .opacity(isLoading ? 0 : 1)
                    .disabled(isLoading)

                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.5)
                        Text("Unlocking...")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 22)

            // ZStack-with-opacity prevents layout recursion on dismissal (see above).
            ZStack {
                HStack {
                    Button("Cancel") {
                        passphrase = ""
                        isPresented = false
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button("Unlock") {
                        Task {
                            await handlePassphrase()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(passphrase.isEmpty)
                }
                .opacity(isLoading ? 0 : 1)
                .disabled(isLoading)

                if isLoading {
                    Button("Cancel") {
                        onCancel()
                        passphrase = ""
                        isPresented = false
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding()
        .frame(width: 350)
        .onAppear {
            DispatchQueue.main.async {
                isPassphraseFieldFocused = true
            }
        }
    }

    private func handlePassphrase() async {
        let passphraseToUse = passphrase
        passphrase = ""
        await onDecrypt(passphraseToUse)
        // Modal dismissal is controlled by isPresented binding
        // On success: viewModel sets showPassphraseModal = false
        // On error: modal stays open, shows responseMessage
    }
}
