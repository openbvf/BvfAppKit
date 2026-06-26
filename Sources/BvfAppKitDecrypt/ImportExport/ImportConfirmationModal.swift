import SwiftUI

/// ImportConfirmationModal: Presents the post-encrypt summary and three actions
/// (Import / Discard / Retry Failed). Also serves crash-recovery for any prior
/// interrupted import to the same destination.
///
/// Thin like PassphraseModalView — bindings + closures, no view-model coupling.
struct ImportConfirmationModal: View {
    let summary: ImportSummary

    /// Called with the user's choice. Modal dismissal is driven by the parent
    /// (which sets the bound item to nil after this fires).
    var onDecision: (ImportDecision) -> Void

    @State private var showFailureDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(summary.isResumed ? "Resume Previous Import" : "Confirm Import")
                .font(.headline)

            if summary.isResumed {
                Text("You paused this earlier — choose what to do with it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label(
                    "\(summary.succeeded) ready to import",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)

                if !summary.failed.isEmpty {
                    Label(
                        "\(summary.failed.count) failed",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                    .onTapGesture {
                        showFailureDetails.toggle()
                    }
                }
            }
            .font(.body)

            if showFailureDetails && !summary.failed.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(summary.failed.prefix(BvfAppKitConfig.maxErrorEntries), id: \.url) { failure in
                            Text("\(failure.url.lastPathComponent): \(failure.errorDescription)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if summary.failed.count > BvfAppKitConfig.maxErrorEntries {
                            Text("… and \(summary.failed.count - BvfAppKitConfig.maxErrorEntries) more")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }

            Text("Importing will prompt for your passphrase to save metadata.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Discard", role: .destructive) {
                    onDecision(.discard)
                }

                Spacer()

                Button("Cancel") {
                    onDecision(.deferred)
                }
                .keyboardShortcut(.cancelAction)

                if !summary.failed.isEmpty {
                    Button("Retry Failed") {
                        onDecision(.retryFailed)
                    }
                }

                Button("Import") {
                    onDecision(.importStaged)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(summary.succeeded == 0)
            }
        }
        .padding()
        .frame(width: 400)
        .interactiveDismissDisabled()
    }
}
