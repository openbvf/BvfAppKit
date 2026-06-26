import SwiftUI

struct TagManagementSheet: View {
    let selectedDates: Set<Date>
    let viewModel: BrowseViewModelBase
    let onDismiss: () -> Void

    @State private var currentTags: [String] = []

    init(
        selectedDates: Set<Date>,
        viewModel: BrowseViewModelBase,
        onDismiss: @escaping () -> Void
    ) {
        self.selectedDates = selectedDates
        self.viewModel = viewModel
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            TagAssignmentView(
                currentTags: Binding(
                    get: { computeCurrentTags() },
                    set: { newTags in
                        viewModel.setTags(newTags, for: Array(selectedDates))
                    }
                ),
                allTags: viewModel.metadata.allTags(),
                filenames: selectedDates.map { $0.filePathString },
                onAdd: { tag in
                    viewModel.addTag(tag, to: Array(selectedDates))
                },
                onRemove: { tag in
                    viewModel.removeTag(tag, from: Array(selectedDates))
                }
            )

            Divider()
                .padding(.top, 8)

            HStack {
                Spacer()
                Button("Done") {
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 320, height: 450)
    }

    private func computeCurrentTags() -> [String] {
        let dates = Array(selectedDates)
        if dates.count == 1 {
            return viewModel.metadata.tags(for: dates[0])
        } else {
            guard let first = dates.first else { return [] }
            var commonTags = Set(viewModel.metadata.tags(for: first))
            for date in dates.dropFirst() {
                commonTags.formIntersection(viewModel.metadata.tags(for: date))
            }
            return Array(commonTags).sorted()
        }
    }
}
