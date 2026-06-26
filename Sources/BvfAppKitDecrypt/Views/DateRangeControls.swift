import SwiftUI

struct DateRangeControls: View {
    @Binding var startDate: Date
    @Binding var endDate: Date
    @Binding var selectedPreset: DateRangePreset?
    let onPresetSelected: (DateRangePreset) -> Void

    @FocusState private var isPickerFocused: Bool

    init(
        startDate: Binding<Date>,
        endDate: Binding<Date>,
        selectedPreset: Binding<DateRangePreset?>,
        onPresetSelected: @escaping (DateRangePreset) -> Void
    ) {
        self._startDate = startDate
        self._endDate = endDate
        self._selectedPreset = selectedPreset
        self.onPresetSelected = onPresetSelected
    }

    var body: some View {
        HStack {
            // Selection is DateRangePreset?; tags must match that exact type,
            // so they're written as DateRangePreset?.none / .some(preset).
            Picker("Preset", selection: $selectedPreset) {
                Text("Date Range").tag(DateRangePreset?.none)
                ForEach(DateRangePreset.allCases, id: \.self) { preset in
                    Text(preset.displayName).tag(DateRangePreset?.some(preset))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .focused($isPickerFocused)
            .onKeyPress { keyPress in
                guard isPickerFocused else { return .ignored }

                let key = keyPress.characters.lowercased()
                if let preset = DateRangePreset.allCases.first(where: {
                    $0.displayName.lowercased().starts(with: key)
                }) {
                    selectedPreset = preset
                    return .handled
                }
                return .ignored
            }
            .onChange(of: selectedPreset) { _, newValue in
                if let newValue {
                    onPresetSelected(newValue)
                }
            }
            .background(
                Button("Focus Date Preset") {
                    isPickerFocused = true
                }
                .keyboardShortcut("d", modifiers: .command)
                .hidden()
            )

            DatePicker(
                "Start Date",
                selection: $startDate,
                displayedComponents: [.date]
            )
            .datePickerStyle(.field)
            .labelsHidden()

            Text("-")

            DatePicker(
                "End Date",
                selection: $endDate,
                displayedComponents: [.date]
            )
            .datePickerStyle(.field)
            .labelsHidden()
        }
    }
}
