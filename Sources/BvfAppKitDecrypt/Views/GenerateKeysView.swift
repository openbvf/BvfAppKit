import SwiftUI

/// View for generating new keypair with passphrase entry and strength feedback
struct GenerateKeysView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase: String = ""
    @State private var passphraseConfirmation: String = ""
    @State private var strengthAssessment: (strength: PassphraseStrength, message: String)?

    let onGenerate: (Result<String, Error>) -> Void

    init(onGenerate: @escaping (Result<String, Error>) -> Void) {
        self.onGenerate = onGenerate
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Generate New Keypair")
                .font(.headline)

            Text("""
            **Your journal is protected with a private key.**
            - It lives on your local hard drive,
            - Protected with this passphrase, which lives in your head.
            - Lose either and you can't read what you wrote.
            - If someone gets both, they can read what you wrote.
            - Anyone can have your public key.
            """)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Enter passphrase:")
                    .font(.subheadline)

                SecureField("Passphrase", text: $passphrase)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: passphrase) { _, newValue in
                        updateStrengthAssessment(newValue)
                    }

                // Strength indicator (always reserves space)
                HStack(spacing: 8) {
                    Circle()
                        .fill(colorForStrength(strengthAssessment?.strength ?? .weak))
                        .frame(width: 8, height: 8)

                    Text(strengthAssessment != nil && !passphrase.isEmpty
                         ? "\(strengthAssessment!.strength.label): \(strengthAssessment!.message)"
                         : " ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .opacity(strengthAssessment != nil && !passphrase.isEmpty ? 1 : 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Confirm passphrase:")
                    .font(.subheadline)

                SecureField("Confirm passphrase", text: $passphraseConfirmation)
                    .textFieldStyle(.roundedBorder)
            }

            // Match status (always reserves space)
            HStack(spacing: 8) {
                Image(systemName: matchIcon)
                    .foregroundStyle(matchColor)
                Text(matchMessage)
                    .font(.caption)
                    .foregroundStyle(matchColor)
            }
            .opacity(showMatchStatus ? 1 : 0)

            Spacer()

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Generate") {
                    handleGenerate()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canGenerate)
            }
        }
        .padding(24)
        .frame(width: 450, height: 440)
    }

    private var canGenerate: Bool {
        !passphrase.isEmpty &&
        passphrase == passphraseConfirmation
    }

    private var showMatchStatus: Bool {
        !passphraseConfirmation.isEmpty
    }

    private var passphrasesMatch: Bool {
        passphrase == passphraseConfirmation
    }

    private var matchIcon: String {
        passphrasesMatch ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private var matchColor: Color {
        passphrasesMatch ? .green : .red
    }

    private var matchMessage: String {
        passphrasesMatch ? "Passphrases match" : "Passphrases do not match"
    }

    private func updateStrengthAssessment(_ newPassphrase: String) {
        strengthAssessment = PassphraseStrengthCalculator.calculate(newPassphrase)
    }

    private func colorForStrength(_ strength: PassphraseStrength) -> Color {
        switch strength {
        case .weak: return .red
        case .moderate: return .orange
        case .strong: return .green
        }
    }

    private func handleGenerate() {
        onGenerate(.success(passphrase))
        passphrase = ""
        passphraseConfirmation = ""
        strengthAssessment = nil
        dismiss()
    }
}
