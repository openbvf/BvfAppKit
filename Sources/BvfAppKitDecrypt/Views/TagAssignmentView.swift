import SwiftUI

struct TagAssignmentView: View {
    @Binding var currentTags: [String]
    let allTags: [String]
    let filenames: [String]
    let onAdd: (String) -> Void
    let onRemove: (String) -> Void

    @State private var newTagInput: String = ""
    @State private var showingSuggestions: Bool = false

    init(
        currentTags: Binding<[String]>,
        allTags: [String],
        filenames: [String],
        onAdd: @escaping (String) -> Void,
        onRemove: @escaping (String) -> Void
    ) {
        self._currentTags = currentTags
        self.allTags = allTags
        self.filenames = filenames
        self.onAdd = onAdd
        self.onRemove = onRemove
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if filenames.count > 1 {
                Text("Manage Tags (\(filenames.count) items)")
                    .font(.headline)
            } else {
                Text("Manage Tags")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("Add tag...", text: $newTagInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            addNewTag()
                        }
                        .onChange(of: newTagInput) { oldValue, newValue in
                            showingSuggestions = !newValue.isEmpty && !suggestions.isEmpty
                        }

                    Button("Add") {
                        addNewTag()
                    }
                    .disabled(newTagInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if showingSuggestions {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(suggestions.prefix(10), id: \.self) { suggestion in
                                Button(action: {
                                    newTagInput = suggestion
                                    addNewTag()
                                }) {
                                    Text(suggestion)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, 2)
                                .padding(.horizontal, 4)
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(4)
                            }
                            if suggestions.count > 10 {
                                Text("\(suggestions.count - 10) more...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 4)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                    .padding(.top, 4)
                }
            }

            if !currentTags.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current Tags:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(currentTags, id: \.self) { tag in
                        HStack {
                            Text(tag)
                            Spacer()
                            Button(action: {
                                onRemove(tag)
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(4)
                    }
                }
            }
        }
        .padding()
        .frame(width: 300)
    }

    private var suggestions: [String] {
        let trimmedInput = newTagInput.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmedInput.isEmpty else { return [] }

        return allTags.filter { tag in
            !currentTags.contains(tag) && tag.lowercased().contains(trimmedInput)
        }
    }

    private func addNewTag() {
        let trimmed = newTagInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !currentTags.contains(trimmed) else {
            newTagInput = ""
            showingSuggestions = false
            return
        }

        onAdd(trimmed)
        newTagInput = ""
        showingSuggestions = false
    }
}
