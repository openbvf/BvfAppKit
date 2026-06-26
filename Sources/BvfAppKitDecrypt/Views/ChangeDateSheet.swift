import SwiftUI


struct ChangeDateSheet<VM: BrowseViewModelBase>: View {
    @Bindable var viewModel: VM
    @Binding var isPresented: Bool
    @State private var isMoving = false

    init(viewModel: VM, isPresented: Binding<Bool>) {
        self.viewModel = viewModel
        self._isPresented = isPresented
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Change Date")
                .font(.headline)

            if isMoving {
                ProgressView()
            } else {
                DatePicker(
                    "New Date",
                    selection: $viewModel.datePickerValue,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.field)

                HStack {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button("Change Date") {
                        isMoving = true
                        let selectedDates = viewModel.selectedDates
                        Task {
                            await viewModel.changeDate(for: selectedDates, to: viewModel.datePickerValue)
                            isPresented = false
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding()
    }
}

