import SwiftUI

/// Adds the tag-management popover to any `View`.
public extension View {
    /// Attach a popover that lets the user manage tags for `date` (or the multi-selection containing it).
    func tagPopover(
        isPresented: Binding<Bool>,
        date: Date,
        selectedDates: Set<Date>,
        viewModel: BrowseViewModelBase
    ) -> some View {
        modifier(TagPopoverModifier(
            isPresented: isPresented,
            date: date,
            selectedDates: selectedDates,
            viewModel: viewModel
        ))
    }
}

private struct TagPopoverModifier: ViewModifier {
    @Binding var isPresented: Bool
    let date: Date
    let selectedDates: Set<Date>
    let viewModel: BrowseViewModelBase

    func body(content: Content) -> some View {
        content
            .popover(isPresented: $isPresented) {
                let targetDates: [Date] = {
                    if selectedDates.contains(date) {
                        return Array(selectedDates)
                    } else {
                        return [date]
                    }
                }()

                TagAssignmentView(
                    currentTags: Binding(
                        get: {
                            if targetDates.count == 1 {
                                return viewModel.metadata.tags(for: targetDates[0])
                            } else {
                                guard let first = targetDates.first else { return [] }
                                var commonTags = Set(viewModel.metadata.tags(for: first))
                                for d in targetDates.dropFirst() {
                                    commonTags.formIntersection(viewModel.metadata.tags(for: d))
                                }
                                return Array(commonTags).sorted()
                            }
                        },
                        set: { newTags in
                            viewModel.setTags(newTags, for: targetDates)
                        }
                    ),
                    allTags: viewModel.metadata.allTags(),
                    filenames: targetDates.map { $0.filePathString },
                    onAdd: { tag in
                        viewModel.addTag(tag, to: targetDates)
                    },
                    onRemove: { tag in
                        viewModel.removeTag(tag, from: targetDates)
                    }
                )
                .frame(width: 300, height: 400)
                .padding()
            }
    }
}
