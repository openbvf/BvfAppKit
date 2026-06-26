import SwiftUI

/// Shared header row: ready indicator, status message, date-range controls, and Show button.
public struct DateRangeRowView: View {
    /// Lower bound of the selected range.
    @Binding public var startDate: Date
    /// Upper bound of the selected range.
    @Binding public var endDate: Date
    /// Currently-selected preset, if any.
    @Binding public var selectedPreset: DateRangePreset?
    /// Whether the app has enough configuration to load.
    public let isReady: Bool
    /// True while loading is in flight (drives Show-button spinner).
    public let isLoading: Bool
    /// Current status/error message bound to the UI.
    public let responseMessage: ResponseMessage?
    /// Configuration error to display when no `responseMessage` is set.
    public let setupErrorMessage: String?
    /// Closure invoked when the user presses Show.
    public let onDecrypt: () async -> Void

    @State private var isHoveringMessage = false
    @State private var isMessageDetailPresented = false

    /// Create the row.
    public init(
        startDate: Binding<Date>,
        endDate: Binding<Date>,
        selectedPreset: Binding<DateRangePreset?>,
        isReady: Bool,
        isLoading: Bool,
        responseMessage: ResponseMessage?,
        setupErrorMessage: String?,
        onDecrypt: @escaping () async -> Void
    ) {
        self._startDate = startDate
        self._endDate = endDate
        self._selectedPreset = selectedPreset
        self.isReady = isReady
        self.isLoading = isLoading
        self.responseMessage = responseMessage
        self.setupErrorMessage = setupErrorMessage
        self.onDecrypt = onDecrypt
    }

    /// SwiftUI body.
    public var body: some View {
        HStack(alignment: .center) {
            ReadyIndicatorView(isReady: isReady)

            // Status messages (priority: response message > setup error)
            if let message = responseMessage {
                let isClickable = message.detail != nil

                Text(message.text)
                    .font(.caption)
                    .foregroundColor(message.type.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .underline(isClickable && isHoveringMessage)
                    .animation(.none, value: responseMessage)
                    .onTapGesture {
                        if isClickable {
                            isMessageDetailPresented = true
                        }
                    }
                    .onHover { hovering in
                        if isClickable {
                            isHoveringMessage = hovering
                        }
                    }
            } else if let error = setupErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            DateRangeControls(
                startDate: $startDate,
                endDate: $endDate,
                selectedPreset: $selectedPreset,
                onPresetSelected: { preset in
                    let range = preset.dateRange()
                    startDate = range.start
                    endDate = range.end
                }
            )

            // Show button (fixed width to prevent layout shift)
            ZStack {
                Button("Show") {
                    Task {
                        await onDecrypt()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .opacity(isLoading ? 0 : 1)
                .disabled(isLoading)
                .animation(.none, value: isLoading)

                if isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                }
            }
            .frame(width: 100, height: 28)
        }
        .sheet(isPresented: $isMessageDetailPresented) {
            if let message = responseMessage {
                MessageDetailView(message: message)
            }
        }
    }
}
