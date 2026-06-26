import SwiftUI
import AppKit

struct MessageDetailView: View {
    let message: ResponseMessage
    @Environment(\.dismiss) private var dismiss

    init(message: ResponseMessage) {
        self.message = message
    }

    private var displayText: String {
        let fullText = message.detail ?? message.text
        let lines = fullText.components(separatedBy: .newlines)

        if lines.count <= 300 {
            return fullText
        } else {
            let truncatedLines = lines.prefix(300)
            let remainingCount = lines.count - 300
            return truncatedLines.joined(separator: "\n") + "\n... and \(remainingCount) more lines"
        }
    }

    private func saveToFile() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.showsTagField = false

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let timestamp = formatter.string(from: Date())
        panel.nameFieldStringValue = "import-report-\(timestamp).txt"

        panel.begin { response in
            if response == .OK, let url = panel.url {
                let fullText = message.detail ?? message.text
                do {
                    try fullText.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: message.type.iconName)
                        .foregroundColor(message.type.color)
                    Text(message.type.displayName)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(message.type.color)
                }

                Spacer()

                Button("Save to File") {
                    saveToFile()
                }

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            Divider()

            ScrollView {
                Text(displayText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(8)
        }
        .padding()
        .frame(width: 600, height: 400)
    }
}
