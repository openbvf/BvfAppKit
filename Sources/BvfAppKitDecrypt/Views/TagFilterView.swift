import SwiftUI

struct TagFilterView: View {
    @Binding var selectedTags: Set<String>
    @Binding var filterMode: TagFilterMode
    let allTags: [String]

    @State private var searchText: String = ""
    @State private var selectedAtOpen: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search tags...", text: $searchText)
                .textFieldStyle(.roundedBorder)

            if allTags.count > 1 {
                Picker("Mode", selection: $filterMode) {
                    Text("Any").tag(TagFilterMode.any)
                    Text("All").tag(TagFilterMode.all)
                }
                .pickerStyle(.segmented)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredTags, id: \.self) { tag in
                        Button(action: {
                            toggleTag(tag)
                        }) {
                            HStack {
                                Image(systemName: selectedTags.contains(tag) ? "checkmark.square.fill" : "square")
                                    .foregroundColor(selectedTags.contains(tag) ? .accentColor : .secondary)
                                Text(tag)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 4)
                    }
                }
            }
            .frame(maxHeight: 200)

            if !selectedTags.isEmpty {
                Button("Clear All") {
                    selectedTags.removeAll()
                }
                .font(.caption)
            }
        }
        .onAppear { selectedAtOpen = selectedTags }
    }

    private var filteredTags: [String] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = trimmed.isEmpty ? allTags : allTags.filter { $0.lowercased().contains(trimmed) }
        return matches.filter { selectedAtOpen.contains($0) } + matches.filter { !selectedAtOpen.contains($0) }
    }

    private func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.remove(tag)
        } else {
            selectedTags.insert(tag)
        }
    }
}
